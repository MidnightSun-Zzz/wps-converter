from __future__ import annotations

from pathlib import Path

import pytest
from pypdf import PdfWriter

from wps_converter.converter import (
    FORMAT_SPECS,
    ConcurrencyLimiter,
    TaskWorkspace,
    sanitize_upload_name,
    stream_file,
    validate_ooxml_output,
    validate_pdf_output,
)
from wps_converter.errors import ServiceError


def test_sanitize_upload_name_blocks_traversal_and_control_characters() -> None:
    safe_name, spec = sanitize_upload_name("../../a\\b/\x00报告.WPS")
    assert safe_name == "_报告.wps"
    assert spec is FORMAT_SPECS[".wps"]


@pytest.mark.parametrize("filename", [None, "", "..", "document.docx"])
def test_sanitize_upload_name_rejects_invalid_names(filename: str | None) -> None:
    with pytest.raises(ServiceError):
        sanitize_upload_name(filename)


def test_validate_ooxml_rejects_missing_file(tmp_path: Path) -> None:
    with pytest.raises(ServiceError) as error:
        validate_ooxml_output(tmp_path / "missing.docx", FORMAT_SPECS[".wps"])
    assert error.value.code == "CONVERSION_FAILED"


def test_validate_pdf_output_accepts_a_readable_pdf(tmp_path: Path) -> None:
    output = tmp_path / "converted.pdf"
    writer = PdfWriter()
    writer.add_blank_page(width=595, height=842)
    with output.open("wb") as pdf:
        writer.write(pdf)

    validate_pdf_output(output)


@pytest.mark.parametrize(
    "payload",
    [
        b"",
        b"not a pdf",
        b"%PDF-1.4\n1 0 obj\n",
        b"%PDF-1.4\n%%EOF",
    ],
)
def test_validate_pdf_output_rejects_invalid_files(
    tmp_path: Path, payload: bytes
) -> None:
    output = tmp_path / "converted.pdf"
    output.write_bytes(payload)

    with pytest.raises(ServiceError) as error:
        validate_pdf_output(output)
    assert error.value.code == "CONVERSION_FAILED"


@pytest.mark.asyncio
async def test_limiter_is_fail_fast_and_reusable() -> None:
    limiter = ConcurrencyLimiter(1)
    assert await limiter.try_acquire() is True
    assert await limiter.try_acquire() is False
    await limiter.release()
    assert await limiter.try_acquire() is True
    await limiter.release()


@pytest.mark.asyncio
async def test_stream_generator_cleanup_on_client_cancellation(
    tmp_path: Path,
) -> None:
    workspace = TaskWorkspace.create(tmp_path / "tasks")
    output = workspace.output_dir / "large.docx"
    output.write_bytes(b"x" * (2 * 1024 * 1024))

    generator = stream_file(output, workspace)
    first_chunk = await anext(generator)
    assert first_chunk
    assert workspace.root.exists()
    await generator.aclose()
    assert not workspace.root.exists()
