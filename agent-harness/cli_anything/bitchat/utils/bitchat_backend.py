from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Callable

from .live_service import LiveServiceClient
from .result import BackendResult


class BitchatBackend:
    def __init__(
        self,
        source_dir: str | Path | None = None,
        backend_mode: str = "auto",
        live_client: Any | None = None,
        harness_runner: Callable[[list[str]], BackendResult] | None = None,
    ):
        self.source_dir = Path(source_dir or Path(__file__).resolve().parents[4]).resolve()
        self.backend_mode = backend_mode
        self.live_client = live_client or LiveServiceClient()
        self.harness_runner = harness_runner

    def status(self) -> BackendResult:
        return self._dispatch("status")

    def peers(self) -> BackendResult:
        return self._dispatch("peers")

    def chats(self) -> BackendResult:
        return self._dispatch("chats")

    def send(self, text: str, to: str | None = None, channel: str | None = None) -> BackendResult:
        return self._dispatch("send", text=text, to=to, channel=channel)

    def command(self, command: str) -> BackendResult:
        return self._dispatch("command", command=command)

    def nickname_get(self) -> BackendResult:
        return self._dispatch("nickname_get")

    def nickname_set(self, nickname: str) -> BackendResult:
        return self._dispatch("nickname_set", nickname=nickname)

    def _dispatch(self, action: str, **kwargs: Any) -> BackendResult:
        if self.backend_mode not in {"auto", "live", "harness"}:
            raise RuntimeError(f"unknown backend mode: {self.backend_mode}")
        if self.backend_mode == "live":
            if not self.live_client.is_running():
                raise RuntimeError("BitChat live service is not running")
            return self.live_client.request(action, **kwargs)
        if self.backend_mode == "auto" and self.live_client.is_running():
            return self.live_client.request(action, **kwargs)
        return self._run(self._harness_args(action, **kwargs))

    @staticmethod
    def _harness_args(command: str, **kwargs: Any) -> list[str]:
        if command == "send":
            args = ["send", "--text", kwargs["text"]]
            if kwargs.get("to"):
                args.extend(["--to", kwargs["to"]])
            if kwargs.get("channel"):
                args.extend(["--channel", kwargs["channel"]])
            return args
        if command == "command":
            return ["command", kwargs["command"]]
        if command == "nickname_get":
            return ["nickname", "get"]
        if command == "nickname_set":
            return ["nickname", "set", kwargs["nickname"]]
        return [command]

    def _run(self, args: list[str]) -> BackendResult:
        if self.harness_runner is not None:
            return self.harness_runner(args)

        binary = os.environ.get("BITCHAT_HARNESS_BINARY")
        if binary:
            cmd = [binary, "--harness", *args]
        else:
            cmd = ["swift", "run", "bitchat", "--", "--harness", *args]

        proc = subprocess.run(
            cmd,
            cwd=self.source_dir,
            text=True,
            capture_output=True,
            check=False,
        )
        objects = self._parse_json_lines(proc.stdout)
        if proc.returncode != 0:
            message = proc.stderr.strip() or proc.stdout.strip() or f"backend exited with {proc.returncode}"
            raise RuntimeError(message)
        return BackendResult(objects=objects, stderr=proc.stderr)

    @staticmethod
    def _parse_json_lines(output: str) -> list[dict[str, Any]]:
        objects: list[dict[str, Any]] = []
        for line in output.splitlines():
            line = line.strip()
            if not line:
                continue
            objects.append(json.loads(line))
        return objects
