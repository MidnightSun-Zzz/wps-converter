from __future__ import annotations

import logging
import os
import shutil
from dataclasses import dataclass
from pathlib import Path


class ConfigurationError(ValueError):
    """Raised when service configuration is invalid."""


def _positive_int(name: str, default: int) -> int:
    raw_value = os.getenv(name, str(default)).strip()
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be a positive integer") from exc
    if value <= 0:
        raise ConfigurationError(f"{name} must be a positive integer")
    return value


@dataclass(frozen=True, slots=True)
class Settings:
    api_key: str
    max_file_size_mb: int = 10
    max_concurrency: int = 4
    conversion_timeout_seconds: int = 120
    soffice_path: str = "soffice"
    log_level: str = "INFO"
    temp_root: Path | None = None

    @property
    def max_file_size_bytes(self) -> int:
        return self.max_file_size_mb * 1024 * 1024

    def resolve_soffice(self) -> str | None:
        resolved = shutil.which(self.soffice_path)
        if resolved is None:
            return None
        path = Path(resolved)
        if not path.is_file() or not os.access(path, os.X_OK):
            return None
        return str(path)

    @classmethod
    def from_env(cls) -> Settings:
        api_key = os.getenv("CONVERTER_API_KEY", "")
        if not api_key:
            raise ConfigurationError(
                "CONVERTER_API_KEY must be configured and must not be empty"
            )

        soffice_path = os.getenv("SOFFICE_PATH", "soffice").strip()
        if not soffice_path:
            raise ConfigurationError("SOFFICE_PATH must not be empty")

        log_level = os.getenv("LOG_LEVEL", "INFO").strip().upper()
        if log_level not in logging.getLevelNamesMapping():
            raise ConfigurationError(f"Unsupported LOG_LEVEL: {log_level}")

        return cls(
            api_key=api_key,
            max_file_size_mb=_positive_int("MAX_FILE_SIZE_MB", 10),
            max_concurrency=_positive_int("MAX_CONCURRENCY", 4),
            conversion_timeout_seconds=_positive_int(
                "CONVERSION_TIMEOUT_SECONDS", 120
            ),
            soffice_path=soffice_path,
            log_level=log_level,
        )
