import json

from click.testing import CliRunner

from cli_anything.bitchat.bitchat_cli import cli
from cli_anything.bitchat.tests.test_core import FakeBackend


def test_core_imsg_like_workflow_with_fake_backend(tmp_path):
    runner = CliRunner()

    chats = runner.invoke(cli, ["--json", "--history-dir", str(tmp_path), "chats"], obj={"backend": FakeBackend()})
    assert chats.exit_code == 0
    assert json.loads(chats.output.strip())["id"] == "mesh"

    sent = runner.invoke(
        cli,
        ["--json", "--history-dir", str(tmp_path), "send", "--to", "alice", "--text", "hi"],
        obj={"backend": FakeBackend()},
    )
    assert sent.exit_code == 0
    assert json.loads(sent.output.strip())["chat_id"] == "dm:alice"

    history = runner.invoke(
        cli,
        ["--json", "--history-dir", str(tmp_path), "history", "--chat-id", "dm:alice"],
        obj={"backend": FakeBackend()},
    )
    assert history.exit_code == 0
    assert json.loads(history.output.strip())["text"] == "hi"


def test_command_passthrough_uses_backend(tmp_path):
    runner = CliRunner()
    result = runner.invoke(
        cli,
        ["--json", "--history-dir", str(tmp_path), "command", "/who"],
        obj={"backend": FakeBackend()},
    )

    assert result.exit_code == 0
    payload = json.loads(result.output.strip())
    assert payload["type"] == "event"
    assert payload["command"] == "/who"
