from __future__ import annotations

import asyncio
import io
import json
import time
import zipfile
from pathlib import Path

import httpx
import pytest

from wps_converter.app import create_app
from wps_converter.config import ConfigurationError, Settings


def make_settings(
    fake_soffice: Path,
    task_root: Path,
    *,
    max_file_size_mb: int = 1,
    max_concurrency: int = 2,
    timeout: int = 3,
) -> Settings:
    return Settings(
        api_key="test-secret",
        max_file_size_mb=max_file_size_mb,
        max_concurrency=max_concurrency,
        conversion_timeout_seconds=timeout,
        soffice_path=str(fake_soffice),
        log_level="INFO",
        temp_root=task_root,
    )


def client_for(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        transport=httpx.ASGITransport(app=create_app(settings)),
        base_url="http://test",
    )


def assert_error(response: httpx.Response, status: int, code: str) -> None:
    assert response.status_code == status
    body = response.json()
    assert body["code"] == code
    assert body["message"]
    assert body["requestId"] == response.headers["X-Request-ID"]


@pytest.mark.asyncio
async def test_health_checks_are_public(fake_soffice: Path, tmp_path: Path) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        live = await client.get("/health/live")
        ready = await client.get("/health/ready")

    assert live.status_code == 200
    assert live.json() == {"status": "ok"}
    assert ready.status_code == 200
    assert ready.json() == {"status": "ready", "soffice": True}
    assert live.headers["X-Request-ID"]
    assert ready.headers["X-Request-ID"]


@pytest.mark.asyncio
async def test_readiness_fails_for_missing_soffice(tmp_path: Path) -> None:
    settings = Settings(
        api_key="test-secret",
        soffice_path=str(tmp_path / "missing-soffice"),
        temp_root=tmp_path / "tasks",
    )
    async with client_for(settings) as client:
        response = await client.get("/health/ready")

    assert response.status_code == 503
    assert response.json()["soffice"] is False
    assert response.json()["requestId"] == response.headers["X-Request-ID"]


@pytest.mark.asyncio
async def test_authentication_is_required(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        missing = await client.post(
            "/api/v1/convert",
            files={"file": ("test.wps", b"VALID")},
        )
        incorrect = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "wrong"},
            files={"file": ("test.wps", b"VALID")},
        )

    assert_error(missing, 401, "AUTH_FAILED")
    assert_error(incorrect, 401, "AUTH_FAILED")


@pytest.mark.asyncio
async def test_missing_file_has_standard_error(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
        )

    assert_error(response, 422, "INVALID_REQUEST")


@pytest.mark.asyncio
async def test_authentication_happens_before_multipart_parsing(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            content=b"this is not multipart",
            headers={"Content-Type": "multipart/form-data; boundary=missing"},
        )

    assert_error(response, 401, "AUTH_FAILED")


@pytest.mark.asyncio
async def test_multiple_uploaded_files_are_rejected(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files=[
                ("file", ("first.wps", b"VALID")),
                ("file", ("second.wps", b"VALID")),
            ],
        )

    assert_error(response, 422, "INVALID_REQUEST")


@pytest.mark.asyncio
async def test_unsupported_extension_is_rejected(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("document.pdf", b"PDF")},
        )

    assert_error(response, 415, "UNSUPPORTED_FORMAT")
    assert not (tmp_path / "tasks").exists()


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("filename", "required_member", "media_type", "target_suffix"),
    [
        (
            "报告.wps",
            "word/document.xml",
            "application/vnd.openxmlformats-officedocument."
            "wordprocessingml.document",
            ".docx",
        ),
        (
            "数据.et",
            "xl/workbook.xml",
            "application/vnd.openxmlformats-officedocument."
            "spreadsheetml.sheet",
            ".xlsx",
        ),
    ],
)
async def test_successful_conversion_response(
    fake_soffice: Path,
    tmp_path: Path,
    filename: str,
    required_member: str,
    media_type: str,
    target_suffix: str,
) -> None:
    task_root = tmp_path / "tasks"
    settings = make_settings(fake_soffice, task_root)
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": (filename, b"VALID", "application/x-untrusted")},
        )

    assert response.status_code == 200
    assert response.headers["content-type"] == media_type
    disposition = response.headers["content-disposition"]
    assert f"filename*=UTF-8''" in disposition
    assert target_suffix in disposition
    with zipfile.ZipFile(io.BytesIO(response.content)) as archive:
        assert required_member in archive.namelist()
        invocation = archive.read("invocation.json").decode()
        assert "--convert-to" in invocation
        assert "UserInstallation=file%3A" not in invocation
        assert "UserInstallation=file:" in invocation
        environment = json.loads(archive.read("environment.json"))
        assert environment["has_api_key"] is False
        assert environment["home"].endswith("/profile/home")
        assert environment["cache"].endswith("/profile/cache")
        assert environment["config"].endswith("/profile/config")
        assert environment["tmp"].endswith("/tmp")
    assert list(task_root.iterdir()) == []


@pytest.mark.asyncio
async def test_filename_is_reduced_to_safe_basename(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(fake_soffice, tmp_path / "tasks")
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("../../目录/报表.wps", b"VALID")},
        )

    assert response.status_code == 200
    disposition = response.headers["content-disposition"]
    assert ".." not in disposition
    assert "%2F" not in disposition
    assert "%E6%8A%A5%E8%A1%A8.docx" in disposition


@pytest.mark.asyncio
async def test_empty_and_oversized_uploads_are_rejected_and_cleaned(
    fake_soffice: Path, tmp_path: Path
) -> None:
    task_root = tmp_path / "tasks"
    settings = make_settings(fake_soffice, task_root, max_file_size_mb=1)
    async with client_for(settings) as client:
        empty = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("empty.wps", b"")},
        )
        oversized = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("large.wps", b"x" * (1024 * 1024 + 1))},
        )

    assert_error(empty, 400, "INVALID_FILE")
    assert_error(oversized, 413, "FILE_TOO_LARGE")
    assert list(task_root.iterdir()) == []


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("payload", "expected_code"),
    [
        (b"FAIL", "CONVERSION_FAILED"),
        (b"NO_OUTPUT", "CONVERSION_FAILED"),
        (b"EMPTY", "CONVERSION_FAILED"),
        (b"BADZIP", "CONVERSION_FAILED"),
        (b"WRONG", "CONVERSION_FAILED"),
    ],
)
async def test_conversion_failures_are_explicit_and_cleaned(
    fake_soffice: Path,
    tmp_path: Path,
    payload: bytes,
    expected_code: str,
) -> None:
    task_root = tmp_path / "tasks"
    settings = make_settings(fake_soffice, task_root)
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("document.wps", payload)},
        )

    assert_error(response, 502, expected_code)
    assert list(task_root.iterdir()) == []


@pytest.mark.asyncio
async def test_timeout_terminates_process_and_cleans_workspace(
    fake_soffice: Path, tmp_path: Path
) -> None:
    task_root = tmp_path / "tasks"
    settings = make_settings(fake_soffice, task_root, timeout=1)
    started = time.monotonic()
    async with client_for(settings) as client:
        response = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("slow.wps", b"SLEEP")},
        )

    assert time.monotonic() - started < 4
    assert_error(response, 504, "CONVERSION_TIMEOUT")
    assert list(task_root.iterdir()) == []


@pytest.mark.asyncio
async def test_concurrency_limit_rejects_without_waiting(
    fake_soffice: Path, tmp_path: Path
) -> None:
    settings = make_settings(
        fake_soffice,
        tmp_path / "tasks",
        max_concurrency=1,
        timeout=1,
    )
    async with client_for(settings) as client:
        first_task = asyncio.create_task(
            client.post(
                "/api/v1/convert",
                headers={"X-API-Key": "test-secret"},
                files={"file": ("slow.wps", b"SLEEP")},
            )
        )
        await asyncio.sleep(0.2)
        started = time.monotonic()
        second = await client.post(
            "/api/v1/convert",
            headers={"X-API-Key": "test-secret"},
            files={"file": ("other.wps", b"VALID")},
        )
        elapsed = time.monotonic() - started
        first = await first_task

    assert elapsed < 0.5
    assert_error(second, 429, "CONCURRENCY_LIMIT")
    assert second.headers["Retry-After"] == "1"
    assert_error(first, 504, "CONVERSION_TIMEOUT")


def test_missing_api_key_fails_configuration(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("CONVERTER_API_KEY", raising=False)
    with pytest.raises(ConfigurationError, match="CONVERTER_API_KEY"):
        Settings.from_env()
