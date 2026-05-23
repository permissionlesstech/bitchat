from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass
class BackendResult:
    objects: list[dict[str, Any]]
    stderr: str = ""
