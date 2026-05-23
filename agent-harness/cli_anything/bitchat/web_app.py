from __future__ import annotations

import argparse
import json
import mimetypes
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib import resources
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from .core.history import HistoryStore
from .utils.live_service import LiveServiceClient, ServicePaths


class WebDataSource:
    def __init__(self, history: HistoryStore | None = None, live_client: Any | None = None):
        self.history = history or HistoryStore()
        self.live_client = live_client or LiveServiceClient()

    def status(self) -> dict[str, Any]:
        try:
            objects = self.live_client.request("status").objects
        except Exception as exc:
            return {
                "type": "status",
                "backend_mode": "live",
                "service_status": "unavailable",
                "message": str(exc),
            }
        status = objects[0] if objects else {"type": "status", "backend_mode": "live"}
        status["service_status"] = "running"
        return status

    def peers(self) -> list[dict[str, Any]]:
        try:
            return self.live_client.request("peers").objects
        except Exception:
            return []

    def chats(self) -> list[dict[str, Any]]:
        by_id: dict[str, dict[str, Any]] = {}
        order: list[str] = []

        for chat in self._live_chats():
            chat_id = chat.get("id")
            if not chat_id:
                continue
            order.append(chat_id)
            by_id[chat_id] = {
                **chat,
                "message_count": 0,
                "last_message_at": None,
                "last_message_text": "",
            }

        for message in self.history.read():
            chat_id = message.get("chat_id")
            if not chat_id:
                continue
            if chat_id not in by_id:
                order.append(chat_id)
                by_id[chat_id] = {
                    "type": "chat",
                    "id": chat_id,
                    "name": self._history_chat_name(chat_id),
                    "service": "bitchat",
                    "message_count": 0,
                    "last_message_at": None,
                    "last_message_text": "",
                }
            by_id[chat_id]["message_count"] += 1
            by_id[chat_id]["last_message_at"] = message.get("created_at") or by_id[chat_id]["last_message_at"]
            by_id[chat_id]["last_message_text"] = message.get("text", "")

        if "mesh" not in by_id:
            order.insert(0, "mesh")
            by_id["mesh"] = {
                "type": "chat",
                "id": "mesh",
                "name": "#mesh",
                "service": "bitchat",
                "message_count": 0,
                "last_message_at": None,
                "last_message_text": "",
            }

        return [by_id[chat_id] for chat_id in order]

    def messages(self, chat_id: str, limit: int = 200) -> list[dict[str, Any]]:
        return self.history.read(chat_id=chat_id, limit=limit)

    def _live_chats(self) -> list[dict[str, Any]]:
        try:
            return self.live_client.request("chats").objects
        except Exception:
            return []

    @staticmethod
    def _history_chat_name(chat_id: str) -> str:
        if chat_id == "mesh":
            return "#mesh"
        return chat_id


class BitchatWebServer:
    def __init__(self, host: str, port: int, source: WebDataSource | None = None):
        self.host = host
        self.port = port
        self.source = source or WebDataSource()
        handler = self._handler_class(self.source)
        self._server = ThreadingHTTPServer((host, port), handler)

    def serve_forever(self) -> None:
        self._server.serve_forever()

    def shutdown(self) -> None:
        self._server.shutdown()
        self._server.server_close()

    @staticmethod
    def _handler_class(source: WebDataSource):
        class BitchatWebHandler(BaseHTTPRequestHandler):
            server_version = "BitChatWeb/0.1"

            def do_GET(self) -> None:
                parsed = urlparse(self.path)
                if parsed.path == "/api/status":
                    self._json(source.status())
                    return
                if parsed.path == "/api/chats":
                    self._json(source.chats())
                    return
                if parsed.path == "/api/peers":
                    self._json(source.peers())
                    return
                if parsed.path == "/api/messages":
                    params = parse_qs(parsed.query)
                    chat_id = (params.get("chat_id") or [""])[0]
                    if not chat_id:
                        self._json({"type": "error", "message": "chat_id is required"}, status=HTTPStatus.BAD_REQUEST)
                        return
                    limit = _int_param(params, "limit", 200)
                    self._json(source.messages(chat_id=chat_id, limit=limit))
                    return
                if parsed.path == "/api/events":
                    self._events(parse_qs(parsed.query))
                    return
                self._static(parsed.path)

            def log_message(self, format: str, *args: Any) -> None:
                return

            def _json(self, payload: Any, status: HTTPStatus = HTTPStatus.OK) -> None:
                data = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _events(self, params: dict[str, list[str]]) -> None:
                chat_id = (params.get("chat_id") or [""])[0] or None
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Connection", "keep-alive")
                self.end_headers()
                seen = {item.get("id") for item in source.history.read(chat_id=chat_id) if item.get("id")}
                while True:
                    try:
                        fresh = [
                            item for item in source.history.read(chat_id=chat_id)
                            if item.get("id") and item.get("id") not in seen
                        ]
                        for item in fresh:
                            seen.add(item["id"])
                            self.wfile.write(f"data: {json.dumps(item, sort_keys=True)}\n\n".encode("utf-8"))
                        if not fresh:
                            self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
                        time.sleep(1.0)
                    except (BrokenPipeError, ConnectionResetError, TimeoutError):
                        return

            def _static(self, request_path: str) -> None:
                relative = "index.html" if request_path in {"/", "/index.html"} else request_path.lstrip("/")
                if ".." in Path(relative).parts:
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                try:
                    data = resources.files("cli_anything.bitchat.web_static").joinpath(relative).read_bytes()
                except FileNotFoundError:
                    self.send_error(HTTPStatus.NOT_FOUND)
                    return
                content_type = mimetypes.guess_type(relative)[0] or "application/octet-stream"
                if relative.endswith(".webmanifest"):
                    content_type = "application/manifest+json"
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", content_type)
                self.send_header("Cache-Control", "no-cache" if relative == "index.html" else "public, max-age=3600")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        return BitchatWebHandler


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description="BitChat local web app")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--base-dir", type=Path, default=ServicePaths.default().base_dir)
    args = parser.parse_args(argv)

    paths = ServicePaths(args.base_dir)
    source = WebDataSource(history=HistoryStore(args.base_dir), live_client=LiveServiceClient(paths=paths))
    BitchatWebServer(args.host, args.port, source).serve_forever()


def _int_param(params: dict[str, list[str]], name: str, default: int) -> int:
    try:
        return int((params.get(name) or [str(default)])[0])
    except ValueError:
        return default


if __name__ == "__main__":
    main()
