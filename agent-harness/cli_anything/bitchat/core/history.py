import json
from pathlib import Path
from typing import Any, Iterable


class HistoryStore:
    def __init__(self, base_dir: str | Path | None = None):
        self.base_dir = Path(base_dir).expanduser() if base_dir else Path.home() / ".bitchat" / "agent-harness"
        self.path = self.base_dir / "history.jsonl"

    def append(self, item: dict[str, Any]) -> None:
        self.base_dir.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n")

    def extend(self, items: Iterable[dict[str, Any]]) -> None:
        for item in items:
            if item.get("type") == "message":
                self.append(item)

    def read(self, chat_id: str | None = None, limit: int | None = None) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        items: list[dict[str, Any]] = []
        with self.path.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                item = json.loads(line)
                if chat_id and item.get("chat_id") != chat_id:
                    continue
                items.append(item)
        if limit is not None:
            return items[-limit:]
        return items
