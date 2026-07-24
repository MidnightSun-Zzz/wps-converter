from __future__ import annotations

from collections.abc import AsyncGenerator

from starlette.datastructures import FormData, Headers
from starlette.formparsers import MultiPartException, MultiPartParser


class UploadTooLarge(MultiPartException):
    """Raised as soon as a multipart file exceeds the configured limit."""


class LimitedUploadParser(MultiPartParser):
    """Starlette multipart parser with an exact per-file byte limit."""

    def __init__(
        self,
        headers: Headers,
        stream: AsyncGenerator[bytes, None],
        *,
        max_file_size: int,
        max_files: int = 1,
        max_fields: int = 10,
        max_part_size: int = 64 * 1024,
    ) -> None:
        super().__init__(
            headers,
            stream,
            max_files=max_files,
            max_fields=max_fields,
            max_part_size=max_part_size,
        )
        self.max_file_size = max_file_size
        self._current_file_size = 0

    def on_part_begin(self) -> None:
        super().on_part_begin()
        self._current_file_size = 0

    def on_headers_finished(self) -> None:
        super().on_headers_finished()
        if (
            self._current_part.file is not None
            and self._current_part.field_name != "file"
        ):
            raise MultiPartException(
                'The uploaded file field must be named "file".'
            )

    def on_part_data(self, data: bytes, start: int, end: int) -> None:
        if self._current_part.file is not None:
            self._current_file_size += end - start
            if self._current_file_size > self.max_file_size:
                raise UploadTooLarge(
                    "The uploaded file exceeds the configured size limit"
                )
        super().on_part_data(data, start, end)

    async def parse(self) -> FormData:
        try:
            return await super().parse()
        except BaseException:
            for temporary_file in self._files_to_close_on_error:
                temporary_file.close()
            raise
