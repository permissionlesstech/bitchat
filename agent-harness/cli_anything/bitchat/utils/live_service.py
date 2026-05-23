from __future__ import annotations

import json
import os
import signal
import shutil
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .result import BackendResult


@dataclass
class ServicePaths:
    base_dir: Path

    @classmethod
    def default(cls) -> "ServicePaths":
        return cls(Path.home() / ".bitchat" / "agent-harness")

    @property
    def metadata_path(self) -> Path:
        return self.base_dir / "service.json"

    @property
    def log_path(self) -> Path:
        return self.base_dir / "service.log"

    @property
    def web_log_path(self) -> Path:
        return self.base_dir / "web.log"


class LiveServiceClient:
    def __init__(self, paths: ServicePaths | None = None, timeout: float = 1.0):
        self.paths = paths or ServicePaths.default()
        self.timeout = timeout

    def is_running(self) -> bool:
        try:
            self.request("status")
        except Exception:
            return False
        return True

    def request(self, action: str, **kwargs: Any) -> BackendResult:
        metadata = self._read_metadata()
        if not metadata:
            raise RuntimeError("BitChat live service is not running")

        payload = {"command": action, "arguments": kwargs}
        data = (json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        host = metadata.get("host", "127.0.0.1")
        port = int(metadata["port"])

        with socket.create_connection((host, port), timeout=self.timeout) as sock:
            sock.settimeout(self.timeout)
            sock.sendall(data)
            chunks: list[bytes] = []
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)

        objects = self._parse_json_lines(b"".join(chunks).decode("utf-8"))
        return BackendResult(objects=objects)

    def _read_metadata(self) -> dict[str, Any] | None:
        if not self.paths.metadata_path.exists():
            return None
        with self.paths.metadata_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)

    @staticmethod
    def _parse_json_lines(output: str) -> list[dict[str, Any]]:
        objects: list[dict[str, Any]] = []
        for line in output.splitlines():
            line = line.strip()
            if line:
                objects.append(json.loads(line))
        return objects


class LiveServiceManager:
    def __init__(
        self,
        source_dir: str | Path | None = None,
        paths: ServicePaths | None = None,
        startup_timeout: float = 45.0,
    ):
        self.source_dir = Path(source_dir or Path(__file__).resolve().parents[4]).resolve()
        self.paths = paths or ServicePaths.default()
        self.startup_timeout = startup_timeout
        self.build_configuration = os.environ.get("BITCHAT_HARNESS_CONFIGURATION", "release").lower()
        if self.build_configuration not in {"debug", "release"}:
            raise RuntimeError("BITCHAT_HARNESS_CONFIGURATION must be 'debug' or 'release'")

    def start(self) -> dict[str, Any]:
        current = self.status()
        if current.get("status") == "running":
            metadata = self._read_metadata() or {}
            if current.get("web_status") != "running":
                self._start_web_service(metadata)
                self._write_metadata(metadata)
                current = self.status()
            current["already_running"] = True
            return current

        self.paths.base_dir.mkdir(parents=True, exist_ok=True)
        port = self._reserve_port()
        launch = self._launch_service(port)
        cmd = launch["command"]
        log_handle = self.paths.log_path.open("a", encoding="utf-8")
        log_handle.write(f"\n--- starting {' '.join(cmd)} ---\n")
        log_handle.flush()
        proc = launch["start"](log_handle)
        log_handle.close()
        pid = int(launch.get("pid") or getattr(proc, "pid", 0))

        metadata = {
            "host": "127.0.0.1",
            "pid": pid,
            "port": port,
            "source_dir": str(self.source_dir),
            "started_at": self._iso_now(),
            "log_path": str(self.paths.log_path),
            "launch_mode": launch["mode"],
            "build_configuration": launch.get("build_configuration", self.build_configuration),
        }
        self._write_metadata(metadata)

        client = LiveServiceClient(paths=self.paths, timeout=0.5)
        deadline = time.time() + self.startup_timeout
        while time.time() < deadline:
            if launch["mode"] == "bundle-open" and (pid <= 0 or not self._process_alive(pid)):
                discovered_pid = self._find_service_pid(port)
                if discovered_pid:
                    pid = discovered_pid
                    metadata["pid"] = pid
                    self._write_metadata(metadata)

            if launch["mode"] == "direct" and proc.poll() is not None:
                try:
                    self.paths.metadata_path.unlink()
                except FileNotFoundError:
                    pass
                raise RuntimeError(f"BitChat live service exited during startup; see {self.paths.log_path}")
            if launch["mode"] == "bundle-open" and pid > 0 and not self._process_alive(pid):
                try:
                    self.paths.metadata_path.unlink()
                except FileNotFoundError:
                    pass
                raise RuntimeError(f"BitChat live service exited during startup; see {self.paths.log_path}")
            if client.is_running():
                self._start_web_service(metadata)
                self._write_metadata(metadata)
                return self.status()
            time.sleep(0.25)

        self._terminate_process(proc.pid)
        try:
            self.paths.metadata_path.unlink()
        except FileNotFoundError:
            pass
        raise RuntimeError(f"BitChat live service did not become ready; see {self.paths.log_path}")

    def status(self) -> dict[str, Any]:
        metadata = self._read_metadata()
        if not metadata:
            return {"type": "service", "status": "stopped", "backend_mode": "harness"}

        pid = int(metadata.get("pid", 0))
        process_alive = self._process_alive(pid)
        if not process_alive:
            return {
                "type": "service",
                "status": "stopped",
                "backend_mode": "harness",
                "pid": pid,
                "port": metadata.get("port"),
                "log_path": metadata.get("log_path"),
            }

        running = self._live_client_running()
        web_pid = int(metadata.get("web_pid", 0))
        web_running = self._process_alive(web_pid)
        status = {
            "type": "service",
            "status": "running" if running else "starting",
            "backend_mode": "live",
            "pid": pid,
            "port": metadata.get("port"),
            "started_at": metadata.get("started_at"),
            "log_path": metadata.get("log_path"),
            "build_configuration": metadata.get("build_configuration"),
            "web_status": "running" if web_running else "stopped",
            "web_pid": web_pid or None,
            "web_port": metadata.get("web_port"),
            "web_url": metadata.get("web_url"),
        }
        return status

    def stop(self) -> dict[str, Any]:
        metadata = self._read_metadata()
        if not metadata:
            return {"type": "service", "status": "stopped"}

        pid = int(metadata.get("pid", 0))
        web_pid = int(metadata.get("web_pid", 0))
        self._terminate_process(web_pid)
        self._terminate_process(pid)

        try:
            self.paths.metadata_path.unlink()
        except FileNotFoundError:
            pass
        return {"type": "service", "status": "stopped"}

    def logs(self, tail: int = 80) -> list[dict[str, Any]]:
        if not self.paths.log_path.exists():
            return [{"type": "event", "event": "service-log", "text": ""}]
        lines = self.paths.log_path.read_text(encoding="utf-8", errors="replace").splitlines()
        return [{"type": "event", "event": "service-log", "text": line} for line in lines[-tail:]]

    def _start_web_service(self, metadata: dict[str, Any]) -> None:
        web_pid = int(metadata.get("web_pid", 0))
        if self._process_alive(web_pid):
            return

        self.paths.base_dir.mkdir(parents=True, exist_ok=True)
        web_port = self._reserve_port()
        host = "127.0.0.1"
        cmd = [
            sys.executable,
            "-m",
            "cli_anything.bitchat.web_app",
            "--host",
            host,
            "--port",
            str(web_port),
            "--base-dir",
            str(self.paths.base_dir),
        ]
        with self.paths.web_log_path.open("a", encoding="utf-8") as log_handle:
            log_handle.write(f"\n--- starting {' '.join(cmd)} ---\n")
            log_handle.flush()
            proc = subprocess.Popen(
                cmd,
                cwd=self.source_dir,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )

        deadline = time.time() + 5.0
        while time.time() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"BitChat web service exited during startup; see {self.paths.web_log_path}")
            if self._port_accepts_connections(host, web_port):
                metadata["web_host"] = host
                metadata["web_pid"] = int(proc.pid)
                metadata["web_port"] = web_port
                metadata["web_url"] = f"http://{host}:{web_port}"
                metadata["web_log_path"] = str(self.paths.web_log_path)
                return
            time.sleep(0.1)

        self._terminate_process(proc.pid)
        raise RuntimeError(f"BitChat web service did not become ready; see {self.paths.web_log_path}")

    def _service_arguments(self, port: int) -> list[str]:
        return [
            "--harness",
            "service",
            "run",
            "--port",
            str(port),
            "--log-file",
            str(self.paths.log_path),
        ]

    def _launch_service(self, port: int) -> dict[str, Any]:
        binary = os.environ.get("BITCHAT_HARNESS_BINARY")
        args = self._service_arguments(port)
        if binary:
            cmd = [binary, *args]

            def start(log_handle):
                return subprocess.Popen(
                    cmd,
                    cwd=self.source_dir,
                    stdout=log_handle,
                    stderr=subprocess.STDOUT,
                    text=True,
                    start_new_session=True,
                )

            return {"mode": "direct", "command": cmd, "pid": 0, "build_configuration": "external", "start": start}

        binary_path = self._prepare_service_bundle()
        bundle_path = binary_path.parents[2]
        cmd = ["/usr/bin/open", "-n", str(bundle_path), "--args", *args]

        def start(log_handle):
            proc = subprocess.Popen(
                cmd,
                cwd=self.source_dir,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                text=True,
                start_new_session=True,
            )
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired as exc:
                proc.kill()
                raise RuntimeError("LaunchServices did not return after opening BitChat harness service") from exc
            if proc.returncode != 0:
                raise RuntimeError(f"LaunchServices failed to open BitChat harness service; see {self.paths.log_path}")
            return proc

        return {"mode": "bundle-open", "command": cmd, "pid": 0, "build_configuration": self.build_configuration, "start": start}

    def _prepare_service_bundle(self) -> Path:
        subprocess.run(self._swift_build_command(), cwd=self.source_dir, check=True, capture_output=True, text=True)
        bin_path = subprocess.run(
            self._swift_bin_path_command(),
            cwd=self.source_dir,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        source_binary = Path(bin_path) / "bitchat"
        bundle_dir = self.source_dir / ".build" / "bitchat-harness.app"
        macos_dir = bundle_dir / "Contents" / "MacOS"
        resources_dir = bundle_dir / "Contents" / "Resources"
        macos_dir.mkdir(parents=True, exist_ok=True)
        resources_dir.mkdir(parents=True, exist_ok=True)
        bundled_binary = macos_dir / "bitchat"
        shutil.copy2(source_binary, bundled_binary)
        shutil.copy2(self.source_dir / "bitchat" / "HarnessInfo.plist", bundle_dir / "Contents" / "Info.plist")
        (bundle_dir / "Contents" / "PkgInfo").write_text("APPL????", encoding="utf-8")
        subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(bundle_dir)], check=True, capture_output=True, text=True)
        return bundled_binary

    def _swift_build_command(self) -> list[str]:
        return ["swift", "build", "-c", self.build_configuration]

    def _swift_bin_path_command(self) -> list[str]:
        return ["swift", "build", "-c", self.build_configuration, "--show-bin-path"]

    @staticmethod
    def _find_service_pid(port: int) -> int | None:
        try:
            output = subprocess.run(
                ["ps", "-axo", "pid=,command="],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        except subprocess.SubprocessError:
            return None
        needle = f"--harness service run --port {port}"
        for line in output.splitlines():
            if needle not in line:
                continue
            if "bitchat-harness.app/Contents/MacOS/bitchat" not in line and "BITCHAT_HARNESS_BINARY" not in line:
                continue
            pid_text = line.strip().split(maxsplit=1)[0]
            try:
                return int(pid_text)
            except ValueError:
                continue
        return None

    def _read_metadata(self) -> dict[str, Any] | None:
        if not self.paths.metadata_path.exists():
            return None
        with self.paths.metadata_path.open("r", encoding="utf-8") as handle:
            return json.load(handle)

    def _write_metadata(self, metadata: dict[str, Any]) -> None:
        self.paths.base_dir.mkdir(parents=True, exist_ok=True)
        tmp_path = self.paths.metadata_path.with_suffix(".tmp")
        with tmp_path.open("w", encoding="utf-8") as handle:
            json.dump(metadata, handle, sort_keys=True)
        tmp_path.replace(self.paths.metadata_path)

    @staticmethod
    def _reserve_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])

    @staticmethod
    def _process_alive(pid: int) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    @classmethod
    def _terminate_process(cls, pid: int) -> None:
        if not cls._process_alive(pid):
            return
        os.kill(pid, signal.SIGTERM)
        deadline = time.time() + 5.0
        while time.time() < deadline and cls._process_alive(pid):
            time.sleep(0.1)
        if cls._process_alive(pid):
            os.kill(pid, signal.SIGKILL)

    def _live_client_running(self) -> bool:
        return LiveServiceClient(paths=self.paths, timeout=0.35).is_running()

    @staticmethod
    def _port_accepts_connections(host: str, port: int) -> bool:
        try:
            with socket.create_connection((host, port), timeout=0.25):
                return True
        except OSError:
            return False

    @staticmethod
    def _iso_now() -> str:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
