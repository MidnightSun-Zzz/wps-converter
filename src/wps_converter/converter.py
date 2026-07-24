from __future__ import annotations

import asyncio
import os
import shutil
import signal
import stat
import tempfile
import unicodedata
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import quote

import aiofiles
from fastapi import UploadFile

from wps_converter.config import Settings
from wps_converter.errors import ServiceError

IO_CHUNK_SIZE = 1024 * 1024
PROCESS_TERMINATION_GRACE_SECONDS = 2


@dataclass(frozen=True, slots=True)
class FormatSpec:
    source_suffix: str
    target_suffix: str
    convert_to: str
    media_type: str
    required_member: str


FORMAT_SPECS = {
    ".wps": FormatSpec(
        source_suffix=".wps",
        target_suffix=".docx",
        convert_to="docx",
        media_type=(
            "application/vnd.openxmlformats-officedocument."
            "wordprocessingml.document"
        ),
        required_member="word/document.xml",
    ),
    ".et": FormatSpec(
        source_suffix=".et",
        target_suffix=".xlsx",
        convert_to="xlsx",
        media_type=(
            "application/vnd.openxmlformats-officedocument."
            "spreadsheetml.sheet"
        ),
        required_member="xl/workbook.xml",
    ),
}


class ConcurrencyLimiter:
    def __init__(self, maximum: int) -> None:
        self._maximum = maximum
        self._active = 0
        self._lock = asyncio.Lock()

    async def try_acquire(self) -> bool:
        async with self._lock:
            if self._active >= self._maximum:
                return False
            self._active += 1
            return True

    async def release(self) -> None:
        async with self._lock:
            if self._active <= 0:
                raise RuntimeError("Concurrency limiter released without acquisition")
            self._active -= 1


@dataclass(slots=True)
class TaskWorkspace:
    root: Path
    input_dir: Path
    output_dir: Path
    profile_dir: Path
    _cleaned: bool = field(default=False, init=False)
    _cleanup_lock: asyncio.Lock = field(default_factory=asyncio.Lock, init=False)

    @classmethod
    def create(cls, temp_root: Path | None = None) -> TaskWorkspace:
        if temp_root is not None:
            temp_root.mkdir(parents=True, exist_ok=True)
        root = Path(
            tempfile.mkdtemp(
                prefix="wps-converter-",
                dir=str(temp_root) if temp_root is not None else None,
            )
        )
        os.chmod(root, stat.S_IRWXU)
        input_dir = root / "input"
        output_dir = root / "output"
        profile_dir = root / "profile"
        for directory in (input_dir, output_dir, profile_dir):
            directory.mkdir(mode=0o700)
        return cls(
            root=root,
            input_dir=input_dir,
            output_dir=output_dir,
            profile_dir=profile_dir,
        )

    async def cleanup(self) -> None:
        async with self._cleanup_lock:
            if self._cleaned:
                return
            await asyncio.to_thread(shutil.rmtree, self.root, True)
            self._cleaned = True


def sanitize_upload_name(filename: str | None) -> tuple[str, FormatSpec]:
    if not filename:
        raise ServiceError(400, "INVALID_FILE", "The uploaded file has no filename")

    basename = filename.replace("\\", "/").rsplit("/", 1)[-1]
    basename = unicodedata.normalize("NFC", basename)
    suffix = Path(basename).suffix.lower()
    spec = FORMAT_SPECS.get(suffix)
    if spec is None:
        raise ServiceError(
            415,
            "UNSUPPORTED_FORMAT",
            "Only .wps and .et files are supported",
        )

    stem = basename[: -len(suffix)]
    cleaned_characters: list[str] = []
    for character in stem:
        if unicodedata.category(character).startswith("C"):
            cleaned_characters.append("_")
        elif character in '<>:"/\\|?*':
            cleaned_characters.append("_")
        else:
            cleaned_characters.append(character)
    safe_stem = "".join(cleaned_characters).strip(" .")
    safe_stem = safe_stem[:180].strip(" .")
    if not safe_stem or safe_stem in {".", ".."}:
        safe_stem = "document"
    return f"{safe_stem}{spec.source_suffix}", spec


async def save_upload(
    upload: UploadFile,
    destination: Path,
    maximum_bytes: int,
) -> int:
    total = 0
    async with aiofiles.open(destination, "wb") as output:
        while chunk := await upload.read(IO_CHUNK_SIZE):
            total += len(chunk)
            if total > maximum_bytes:
                raise ServiceError(
                    413,
                    "FILE_TOO_LARGE",
                    "The uploaded file exceeds the configured size limit",
                )
            await output.write(chunk)
    if total == 0:
        raise ServiceError(400, "INVALID_FILE", "The uploaded file is empty")
    return total


async def _terminate_process_group(process: asyncio.subprocess.Process) -> None:
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        await asyncio.wait_for(
            process.wait(), timeout=PROCESS_TERMINATION_GRACE_SECONDS
        )
        return
    except TimeoutError:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    await process.wait()


async def run_conversion(
    input_path: Path,
    workspace: TaskWorkspace,
    spec: FormatSpec,
    settings: Settings,
) -> tuple[Path, int]:
    expected_output = workspace.output_dir / f"{input_path.stem}{spec.target_suffix}"
    process_home = workspace.profile_dir / "home"
    process_cache = workspace.profile_dir / "cache"
    process_config = workspace.profile_dir / "config"
    process_tmp = workspace.root / "tmp"
    for directory in (process_home, process_cache, process_config, process_tmp):
        directory.mkdir(mode=0o700)
    process_environment = {
        key: value
        for key in ("PATH", "LANG", "LC_ALL", "TZ")
        if (value := os.environ.get(key)) is not None
    }
    process_environment.update(
        {
            "HOME": str(process_home),
            "XDG_CACHE_HOME": str(process_cache),
            "XDG_CONFIG_HOME": str(process_config),
            "TMPDIR": str(process_tmp),
        }
    )
    command = (
        settings.soffice_path,
        "--headless",
        "--nologo",
        "--nodefault",
        "--nolockcheck",
        "--nofirststartwizard",
        f"-env:UserInstallation={workspace.profile_dir.resolve().as_uri()}",
        "--convert-to",
        spec.convert_to,
        "--outdir",
        str(workspace.output_dir),
        str(input_path),
    )
    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True,
            env=process_environment,
        )
    except (FileNotFoundError, PermissionError, OSError) as exc:
        raise ServiceError(
            502,
            "CONVERSION_FAILED",
            "LibreOffice could not be started",
        ) from exc

    try:
        exit_code = await asyncio.wait_for(
            process.wait(), timeout=settings.conversion_timeout_seconds
        )
    except TimeoutError as exc:
        await _terminate_process_group(process)
        raise ServiceError(
            504,
            "CONVERSION_TIMEOUT",
            "The document conversion timed out",
        ) from exc
    except asyncio.CancelledError:
        await _terminate_process_group(process)
        raise

    if exit_code != 0:
        raise ServiceError(
            502,
            "CONVERSION_FAILED",
            "LibreOffice could not recognize or convert this document",
        )
    await asyncio.to_thread(validate_ooxml_output, expected_output, spec)
    return expected_output, exit_code


def validate_ooxml_output(output_path: Path, spec: FormatSpec) -> None:
    try:
        file_stat = output_path.stat()
    except FileNotFoundError as exc:
        raise ServiceError(
            502,
            "CONVERSION_FAILED",
            "LibreOffice did not produce a conversion result",
        ) from exc
    if not output_path.is_file() or file_stat.st_size <= 0:
        raise ServiceError(
            502,
            "CONVERSION_FAILED",
            "LibreOffice produced an empty or invalid conversion result",
        )
    try:
        with zipfile.ZipFile(output_path) as archive:
            members = set(archive.namelist())
            if "[Content_Types].xml" not in members or spec.required_member not in members:
                raise ServiceError(
                    502,
                    "CONVERSION_FAILED",
                    "LibreOffice produced a file with an unexpected format",
                )
            if archive.testzip() is not None:
                raise ServiceError(
                    502,
                    "CONVERSION_FAILED",
                    "LibreOffice produced a corrupt conversion result",
                )
    except (zipfile.BadZipFile, OSError) as exc:
        raise ServiceError(
            502,
            "CONVERSION_FAILED",
            "LibreOffice produced an invalid conversion result",
        ) from exc


async def stream_file(output_path: Path, workspace: TaskWorkspace):
    try:
        async with aiofiles.open(output_path, "rb") as converted:
            while chunk := await converted.read(IO_CHUNK_SIZE):
                yield chunk
    finally:
        await workspace.cleanup()


def content_disposition(filename: str) -> str:
    ascii_name = unicodedata.normalize("NFKD", filename).encode(
        "ascii", "ignore"
    ).decode("ascii")
    ascii_name = "".join(
        character if 32 <= ord(character) < 127 and character not in '"\\'
        else "_"
        for character in ascii_name
    )
    if not ascii_name:
        ascii_name = f"converted{Path(filename).suffix}"
    encoded_name = quote(filename, safe="")
    return (
        f'attachment; filename="{ascii_name}"; '
        f"filename*=UTF-8''{encoded_name}"
    )
