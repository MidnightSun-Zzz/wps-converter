from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(slots=True)
class ServiceError(Exception):
    status_code: int
    code: str
    message: str
    headers: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        Exception.__init__(self, self.message)
