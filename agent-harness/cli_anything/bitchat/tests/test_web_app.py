import json
import socket
import threading
from urllib.error import HTTPError
from urllib.request import urlopen

from cli_anything.bitchat.core.history import HistoryStore
from cli_anything.bitchat.utils.bitchat_backend import BackendResult
from cli_anything.bitchat.web_app import BitchatWebServer, WebDataSource


class FakeLiveClient:
    def request(self, action, **kwargs):
        if action == "status":
            return BackendResult([
                {
                    "type": "status",
                    "backend_mode": "live",
                    "nickname": "agent",
                    "bluetooth_state": "CBManagerState(rawValue: 5)",
                    "connected_peer_count": 0,
                }
            ])
        if action == "chats":
            return BackendResult([
                {"type": "chat", "id": "mesh", "name": "#mesh", "backend_mode": "live"},
            ])
        if action == "peers":
            return BackendResult([
                {"type": "peer", "id": "peer1", "nickname": "alice", "connected": True},
            ])
        raise AssertionError(f"unexpected action: {action}")


def test_web_data_source_merges_live_chats_with_history_only_dm(tmp_path):
    store = HistoryStore(tmp_path)
    store.append({"type": "message", "id": "1", "chat_id": "mesh", "sender": "agent", "text": "hello"})
    store.append({"type": "message", "id": "2", "chat_id": "dm:abc123", "sender": "alice", "text": "secret"})
    source = WebDataSource(history=store, live_client=FakeLiveClient())

    chats = source.chats()

    assert [chat["id"] for chat in chats] == ["mesh", "dm:abc123"]
    assert chats[1]["name"] == "dm:abc123"
    assert chats[1]["message_count"] == 1


def test_web_server_serves_api_and_static_shell(tmp_path):
    store = HistoryStore(tmp_path)
    store.append({"type": "message", "id": "1", "chat_id": "mesh", "sender": "alice", "text": "hello"})
    source = WebDataSource(history=store, live_client=FakeLiveClient())
    server = BitchatWebServer("127.0.0.1", _free_port(), source)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://{server.host}:{server.port}"
    try:
        index = _get_text(f"{base_url}/")
        manifest = json.loads(_get_text(f"{base_url}/manifest.webmanifest"))
        status = json.loads(_get_text(f"{base_url}/api/status"))
        chats = json.loads(_get_text(f"{base_url}/api/chats"))
        messages = json.loads(_get_text(f"{base_url}/api/messages?chat_id=mesh"))

        assert "BitChat" in index
        assert manifest["name"] == "BitChat Local"
        assert status["nickname"] == "agent"
        assert chats[0]["id"] == "mesh"
        assert messages[0]["text"] == "hello"
    finally:
        server.shutdown()
        thread.join(timeout=2)


def test_messages_api_rejects_missing_chat_id(tmp_path):
    source = WebDataSource(history=HistoryStore(tmp_path), live_client=FakeLiveClient())
    server = BitchatWebServer("127.0.0.1", _free_port(), source)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        try:
            _get_text(f"http://{server.host}:{server.port}/api/messages")
        except HTTPError as exc:
            assert exc.code == 400
        else:
            raise AssertionError("expected missing chat_id to fail")
    finally:
        server.shutdown()
        thread.join(timeout=2)


def test_frontend_renders_newest_first_with_copy_buttons():
    resources = __import__("importlib.resources").resources
    app_js = resources.files("cli_anything.bitchat.web_static").joinpath("app.js").read_text(encoding="utf-8")
    service_worker = resources.files("cli_anything.bitchat.web_static").joinpath("sw.js").read_text(encoding="utf-8")
    index = resources.files("cli_anything.bitchat.web_static").joinpath("index.html").read_text(encoding="utf-8")

    assert 'href="/app.css?v=2"' in index
    assert 'src="/app.js?v=2"' in index
    assert "newestFirst" in app_js
    assert "message-copy" in app_js
    assert "copyMessageText" in app_js
    assert 'CACHE_NAME = "bitchat-local-v2"' in service_worker


def _free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _get_text(url):
    with urlopen(url, timeout=2) as response:
        return response.read().decode("utf-8")
