import json

from click.testing import CliRunner

from cli_anything.bitchat.bitchat_cli import cli
from cli_anything.bitchat.core.history import HistoryStore
from cli_anything.bitchat.core.session import SessionState
from cli_anything.bitchat.utils.bitchat_backend import BackendResult


class FakeBackend:
    def status(self):
        return BackendResult([{"type": "status", "nickname": "agent", "my_peer_id": "abc"}])

    def peers(self):
        return BackendResult([{"type": "peer", "id": "peer1", "nickname": "alice"}])

    def chats(self):
        return BackendResult([{"type": "chat", "id": "mesh", "name": "#mesh"}])

    def send(self, text, to=None, channel=None):
        return BackendResult([
            {
                "type": "message",
                "id": "m1",
                "chat_id": channel or (f"dm:{to}" if to else "mesh"),
                "sender": "agent",
                "text": text,
            }
        ])

    def command(self, command):
        return BackendResult([{"type": "event", "command": command, "text": "online: alice"}])

    def nickname_get(self):
        return BackendResult([{"type": "status", "nickname": "agent"}])

    def nickname_set(self, nickname):
        return BackendResult([{"type": "status", "nickname": nickname}])


class FakeServiceManager:
    def __init__(self):
        self.started = False
        self.stopped = False

    def start(self):
        self.started = True
        return {"type": "service", "status": "running", "backend_mode": "live", "pid": 123, "port": 4567}

    def status(self):
        status = "running" if self.started and not self.stopped else "stopped"
        return {"type": "service", "status": status, "backend_mode": "live" if self.started else "harness"}

    def stop(self):
        self.stopped = True
        return {"type": "service", "status": "stopped"}

    def logs(self, tail=80):
        return [{"type": "event", "event": "service-log", "text": f"tail={tail}"}]


class FakeLiveClient:
    def __init__(self, running=True):
        self.running = running
        self.requests = []

    def is_running(self):
        return self.running

    def request(self, action, **kwargs):
        self.requests.append((action, kwargs))
        return BackendResult([{"type": "status", "backend_mode": "live", "command": action, **kwargs}])


def test_history_store_filters_by_chat(tmp_path):
    store = HistoryStore(tmp_path)
    store.append({"type": "message", "id": "1", "chat_id": "mesh", "text": "hello"})
    store.append({"type": "message", "id": "2", "chat_id": "dm:alice", "text": "secret"})

    assert [item["id"] for item in store.read(chat_id="mesh")] == ["1"]
    assert [item["id"] for item in store.read(limit=1)] == ["2"]


def test_session_state_tracks_channel_and_undo_redo():
    state = SessionState()
    state.select_chat("mesh")
    state.select_chat("dm:alice")

    assert state.current_chat == "dm:alice"
    assert state.undo() == "mesh"
    assert state.current_chat == "mesh"
    assert state.redo() == "dm:alice"


def test_cli_status_emits_single_json_line(tmp_path):
    runner = CliRunner()
    result = runner.invoke(cli, ["--json", "--history-dir", str(tmp_path), "status"], obj={"backend": FakeBackend()})

    assert result.exit_code == 0
    payload = json.loads(result.output.strip())
    assert payload["type"] == "status"
    assert payload["nickname"] == "agent"


def test_cli_send_appends_harness_history(tmp_path):
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["--json", "--history-dir", str(tmp_path), "send", "--text", "hello"],
        obj={"backend": FakeBackend()},
    )

    assert result.exit_code == 0
    assert json.loads(result.output.strip())["text"] == "hello"
    assert HistoryStore(tmp_path).read(chat_id="mesh")[0]["text"] == "hello"


def test_cli_service_start_emits_json(tmp_path):
    runner = CliRunner()
    service = FakeServiceManager()
    result = runner.invoke(
        cli,
        ["--json", "--history-dir", str(tmp_path), "service", "start"],
        obj={"service_manager": service},
    )

    assert result.exit_code == 0
    payload = json.loads(result.output.strip())
    assert payload["type"] == "service"
    assert payload["status"] == "running"
    assert service.started is True


def test_cli_service_logs_emits_json_lines(tmp_path):
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["--json", "--history-dir", str(tmp_path), "service", "logs", "--tail", "12"],
        obj={"service_manager": FakeServiceManager()},
    )

    assert result.exit_code == 0
    payload = json.loads(result.output.strip())
    assert payload["type"] == "event"
    assert payload["text"] == "tail=12"
