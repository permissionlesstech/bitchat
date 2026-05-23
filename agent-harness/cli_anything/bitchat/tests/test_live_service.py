import json

from cli_anything.bitchat.utils.bitchat_backend import BitchatBackend, BackendResult


class FakeLiveClient:
    def __init__(self, running):
        self.running = running
        self.requests = []

    def is_running(self):
        return self.running

    def request(self, action, **kwargs):
        self.requests.append((action, kwargs))
        return BackendResult([{"type": "status", "backend_mode": "live", "command": action, **kwargs}])


class FakeHarnessRunner:
    def __init__(self):
        self.calls = []

    def __call__(self, args):
        self.calls.append(args)
        return BackendResult([{"type": "status", "backend_mode": "harness"}])


def test_auto_backend_uses_live_service_when_running(tmp_path):
    live = FakeLiveClient(running=True)
    harness = FakeHarnessRunner()
    backend = BitchatBackend(source_dir=tmp_path, backend_mode="auto", live_client=live, harness_runner=harness)

    result = backend.send(text="hello", channel="mesh")

    assert result.objects[0]["backend_mode"] == "live"
    assert live.requests == [("send", {"text": "hello", "to": None, "channel": "mesh"})]
    assert harness.calls == []


def test_auto_backend_falls_back_to_harness_when_service_is_stopped(tmp_path):
    live = FakeLiveClient(running=False)
    harness = FakeHarnessRunner()
    backend = BitchatBackend(source_dir=tmp_path, backend_mode="auto", live_client=live, harness_runner=harness)

    result = backend.status()

    assert result.objects[0]["backend_mode"] == "harness"
    assert live.requests == []
    assert harness.calls == [["status"]]


def test_live_backend_requires_running_service(tmp_path):
    live = FakeLiveClient(running=False)
    backend = BitchatBackend(source_dir=tmp_path, backend_mode="live", live_client=live, harness_runner=FakeHarnessRunner())

    try:
        backend.status()
    except RuntimeError as exc:
        assert "live service is not running" in str(exc)
    else:
        raise AssertionError("expected live backend to require the service")


def test_live_backend_forwards_slash_commands(tmp_path):
    live = FakeLiveClient(running=True)
    backend = BitchatBackend(source_dir=tmp_path, backend_mode="live", live_client=live, harness_runner=FakeHarnessRunner())

    result = backend.command("/who")

    assert result.objects[0]["backend_mode"] == "live"
    assert live.requests == [("command", {"command": "/who"})]


def test_live_service_manager_builds_bundle_in_release_by_default(tmp_path, monkeypatch):
    monkeypatch.delenv("BITCHAT_HARNESS_CONFIGURATION", raising=False)
    from cli_anything.bitchat.utils.live_service import LiveServiceManager

    manager = LiveServiceManager(source_dir=tmp_path)

    assert manager.build_configuration == "release"
    assert manager._swift_build_command() == ["swift", "build", "-c", "release"]
    assert manager._swift_bin_path_command() == ["swift", "build", "-c", "release", "--show-bin-path"]


def test_live_service_manager_allows_debug_bundle_for_testnet(tmp_path, monkeypatch):
    monkeypatch.setenv("BITCHAT_HARNESS_CONFIGURATION", "debug")
    from cli_anything.bitchat.utils.live_service import LiveServiceManager

    manager = LiveServiceManager(source_dir=tmp_path)

    assert manager.build_configuration == "debug"
    assert manager._swift_build_command() == ["swift", "build", "-c", "debug"]
