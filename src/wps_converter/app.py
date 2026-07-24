from __future__ import annotations

import asyncio
import logging
import secrets
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated, AsyncIterator, cast
from uuid import uuid4

from fastapi import Depends, FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.background import BackgroundTask
from starlette.datastructures import FormData, UploadFile
from starlette.formparsers import MultiPartException

from wps_converter.config import Settings
from wps_converter.converter import (
    ConcurrencyLimiter,
    TaskWorkspace,
    content_disposition,
    run_conversion,
    sanitize_upload_name,
    save_upload,
    stream_file,
)
from wps_converter.errors import ServiceError
from wps_converter.multipart import LimitedUploadParser, UploadTooLarge

LOGGER = logging.getLogger("wps_converter")


def _request_id(request: Request) -> str:
    return getattr(request.state, "request_id", str(uuid4()))


def _error_response(request: Request, error: ServiceError) -> JSONResponse:
    return JSONResponse(
        status_code=error.status_code,
        content={
            "code": error.code,
            "message": error.message,
            "requestId": _request_id(request),
        },
        headers=error.headers,
    )


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or Settings.from_env()
    logging.basicConfig(
        level=configured.log_level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    limiter = ConcurrencyLimiter(configured.max_concurrency)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        LOGGER.info(
            "service_started max_file_size_mb=%d max_concurrency=%d timeout_seconds=%d",
            configured.max_file_size_mb,
            configured.max_concurrency,
            configured.conversion_timeout_seconds,
        )
        yield
        LOGGER.info("service_stopped")

    app = FastAPI(
        title="WPS Converter",
        version="0.1.0",
        lifespan=lifespan,
    )
    app.state.settings = configured
    app.state.limiter = limiter

    @app.middleware("http")
    async def add_request_id(request: Request, call_next):
        request.state.request_id = str(uuid4())
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        return response

    @app.exception_handler(ServiceError)
    async def handle_service_error(
        request: Request, error: ServiceError
    ) -> JSONResponse:
        return _error_response(request, error)

    @app.exception_handler(RequestValidationError)
    async def handle_validation_error(
        request: Request, _: RequestValidationError
    ) -> JSONResponse:
        return _error_response(
            request,
            ServiceError(
                422,
                "INVALID_REQUEST",
                "The multipart request must contain exactly one file field",
            ),
        )

    @app.exception_handler(Exception)
    async def handle_unexpected_error(
        request: Request, error: Exception
    ) -> JSONResponse:
        LOGGER.exception(
            "request_failed request_id=%s error_type=%s",
            _request_id(request),
            type(error).__name__,
        )
        return _error_response(
            request,
            ServiceError(
                500,
                "INTERNAL_ERROR",
                "An unexpected internal error occurred",
            ),
        )

    async def authenticate(
        request: Request,
        api_key: Annotated[str | None, Header(alias="X-API-Key")] = None,
    ) -> None:
        if api_key is None or not secrets.compare_digest(
            api_key, configured.api_key
        ):
            LOGGER.warning(
                "authentication_failed request_id=%s", _request_id(request)
            )
            raise ServiceError(
                401,
                "AUTH_FAILED",
                "A valid X-API-Key header is required",
            )

    @app.get("/health/live")
    async def live() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/health/ready")
    async def ready(request: Request):
        if configured.resolve_soffice() is None:
            return JSONResponse(
                status_code=503,
                content={
                    "status": "not_ready",
                    "soffice": False,
                    "requestId": _request_id(request),
                },
            )
        return {"status": "ready", "soffice": True}

    @app.post("/api/v1/convert", dependencies=[Depends(authenticate)])
    async def convert(request: Request) -> StreamingResponse:
        request_id = _request_id(request)
        started = time.monotonic()
        size = 0
        outcome = "failed"
        exit_code: int | None = None
        source_extension = "unknown"
        form: FormData | None = None
        workspace: TaskWorkspace | None = None
        resources_released = False
        release_lock = asyncio.Lock()
        acquired = await limiter.try_acquire()
        if not acquired:
            raise ServiceError(
                429,
                "CONCURRENCY_LIMIT",
                "The conversion concurrency limit has been reached",
                headers={"Retry-After": "1"},
            )

        async def release_resources() -> None:
            nonlocal resources_released
            async with release_lock:
                if resources_released:
                    return
                if workspace is not None:
                    await workspace.cleanup()
                await limiter.release()
                resources_released = True
                LOGGER.info(
                    "conversion_finished request_id=%s source_extension=%s "
                    "size_bytes=%d outcome=%s exit_code=%s duration_ms=%d",
                    request_id,
                    source_extension,
                    size,
                    outcome,
                    exit_code if exit_code is not None else "none",
                    int((time.monotonic() - started) * 1000),
                )

        try:
            content_type = request.headers.get("content-type", "")
            if content_type.split(";", 1)[0].strip().lower() != (
                "multipart/form-data"
            ):
                raise ServiceError(
                    422,
                    "INVALID_REQUEST",
                    "The multipart request must contain exactly one file field",
                )
            try:
                form = await LimitedUploadParser(
                    request.headers,
                    request.stream(),
                    max_file_size=configured.max_file_size_bytes,
                ).parse()
            except UploadTooLarge as exc:
                raise ServiceError(
                    413,
                    "FILE_TOO_LARGE",
                    "The uploaded file exceeds the configured size limit",
                ) from exc
            except MultiPartException as exc:
                raise ServiceError(
                    422,
                    "INVALID_REQUEST",
                    "The multipart request must contain exactly one file field",
                ) from exc

            uploaded_items = [
                value
                for _, value in form.multi_items()
                if isinstance(value, UploadFile)
            ]
            file_values = form.getlist("file")
            if (
                len(uploaded_items) != 1
                or len(file_values) != 1
                or not isinstance(file_values[0], UploadFile)
            ):
                raise ServiceError(
                    422,
                    "INVALID_REQUEST",
                    "The multipart request must contain exactly one file field",
                )
            file = cast(UploadFile, file_values[0])
            safe_name, spec = sanitize_upload_name(file.filename)
            source_extension = spec.source_suffix
            workspace = TaskWorkspace.create(configured.temp_root)
            input_path = workspace.input_dir / safe_name
            size = await save_upload(
                file,
                input_path,
                configured.max_file_size_bytes,
            )
            output_path, exit_code = await run_conversion(
                input_path,
                workspace,
                spec,
                configured,
            )
            output_name = f"{Path(safe_name).stem}{spec.target_suffix}"
            response = StreamingResponse(
                stream_file(
                    output_path,
                    workspace,
                    cleanup_callback=release_resources,
                ),
                media_type=spec.media_type,
                headers={
                    "Content-Disposition": content_disposition(output_name),
                },
                background=BackgroundTask(release_resources),
            )
            await form.close()
            form = None
            outcome = "success"
            return response
        except asyncio.CancelledError:
            outcome = "cancelled"
            raise
        finally:
            if form is not None:
                await form.close()
            if outcome != "success":
                await release_resources()

    return app
