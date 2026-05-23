from __future__ import annotations

import json
import shlex
import sys
import time
from pathlib import Path
from typing import Any

import click

from .core.history import HistoryStore
from .core.session import SessionState
from .utils.bitchat_backend import BitchatBackend
from .utils.live_service import LiveServiceManager


def emit(items: list[dict[str, Any]], as_json: bool) -> None:
    for item in items:
        if as_json:
            click.echo(json.dumps(item, sort_keys=True, separators=(",", ":")))
        else:
            click.echo(humanize(item))


def humanize(item: dict[str, Any]) -> str:
    kind = item.get("type", "object")
    if kind == "status":
        return f"nickname={item.get('nickname', '')} peer={item.get('my_peer_id', '')} channel={item.get('active_channel', '')}"
    if kind == "peer":
        return f"{item.get('id', '')}\t{item.get('nickname', '')}\t{item.get('transport', 'mesh')}"
    if kind == "chat":
        return f"{item.get('id', '')}\t{item.get('name', '')}"
    if kind == "message":
        return f"[{item.get('chat_id', '')}] <{item.get('sender', '')}> {item.get('text', '')}"
    if kind == "event":
        return item.get("text") or item.get("event") or json.dumps(item, sort_keys=True)
    if kind == "service":
        return f"service={item.get('status', '')} backend={item.get('backend_mode', '')} pid={item.get('pid', '')}"
    if kind == "error":
        return f"error: {item.get('message', '')}"
    return json.dumps(item, sort_keys=True)


def get_backend(ctx: click.Context) -> Any:
    injected = (ctx.obj or {}).get("backend")
    return injected if injected is not None else BitchatBackend(backend_mode=(ctx.obj or {}).get("backend_mode", "auto"))


def get_service_manager(ctx: click.Context) -> Any:
    injected = (ctx.obj or {}).get("service_manager")
    return injected if injected is not None else LiveServiceManager()


def get_history(ctx: click.Context) -> HistoryStore:
    return HistoryStore((ctx.obj or {}).get("history_dir"))


@click.group(invoke_without_command=True)
@click.option("--json", "as_json", is_flag=True, help="Emit newline-delimited JSON.")
@click.option(
    "--backend",
    "backend_mode",
    type=click.Choice(["auto", "live", "harness"]),
    default="auto",
    show_default=True,
    help="Backend for BitChat operations.",
)
@click.option("--history-dir", type=click.Path(path_type=Path), help="Override harness history directory.")
@click.pass_context
def cli(ctx: click.Context, as_json: bool, backend_mode: str, history_dir: Path | None):
    """BitChat CLI-Anything harness."""
    ctx.ensure_object(dict)
    ctx.obj["as_json"] = as_json
    ctx.obj["backend_mode"] = backend_mode
    if history_dir is not None:
        ctx.obj["history_dir"] = history_dir
    if ctx.invoked_subcommand is None:
        repl(ctx)


@cli.command()
@click.pass_context
def status(ctx: click.Context):
    emit(get_backend(ctx).status().objects, ctx.obj["as_json"])


@cli.command()
@click.pass_context
def peers(ctx: click.Context):
    emit(get_backend(ctx).peers().objects, ctx.obj["as_json"])


@cli.command()
@click.pass_context
def chats(ctx: click.Context):
    emit(get_backend(ctx).chats().objects, ctx.obj["as_json"])


@cli.command()
@click.option("--text", required=True, help="Message text to send.")
@click.option("--to", help="Peer nickname or peer id for private message.")
@click.option("--channel", help="Target chat id, such as mesh or geo:dr5rs.")
@click.pass_context
def send(ctx: click.Context, text: str, to: str | None, channel: str | None):
    result = get_backend(ctx).send(text=text, to=to, channel=channel)
    get_history(ctx).extend(result.objects)
    emit(result.objects, ctx.obj["as_json"])


@cli.command("history")
@click.option("--chat-id", help="Filter by chat id.")
@click.option("--limit", default=50, show_default=True, help="Maximum messages to show.")
@click.pass_context
def history_cmd(ctx: click.Context, chat_id: str | None, limit: int):
    emit(get_history(ctx).read(chat_id=chat_id, limit=limit), ctx.obj["as_json"])


@cli.command()
@click.option("--chat-id", help="Filter streamed history by chat id.")
@click.option("--once", is_flag=True, help="Emit current harness history and exit.")
@click.option("--interval", default=1.0, show_default=True, help="Polling interval in seconds.")
@click.pass_context
def watch(ctx: click.Context, chat_id: str | None, once: bool, interval: float):
    seen: set[str] = set()
    while True:
        items = get_history(ctx).read(chat_id=chat_id)
        fresh = [item for item in items if item.get("id") not in seen]
        for item in fresh:
            if item.get("id"):
                seen.add(item["id"])
        emit(fresh, ctx.obj["as_json"])
        if once:
            return
        time.sleep(interval)


@cli.command("command")
@click.argument("command_text", nargs=-1, required=True)
@click.pass_context
def command_cmd(ctx: click.Context, command_text: tuple[str, ...]):
    command = " ".join(command_text)
    emit(get_backend(ctx).command(command).objects, ctx.obj["as_json"])


@cli.group()
def nickname():
    """Get or set the BitChat nickname."""


@nickname.command("get")
@click.pass_context
def nickname_get(ctx: click.Context):
    emit(get_backend(ctx).nickname_get().objects, ctx.obj["as_json"])


@nickname.command("set")
@click.argument("value")
@click.pass_context
def nickname_set(ctx: click.Context, value: str):
    emit(get_backend(ctx).nickname_set(value).objects, ctx.obj["as_json"])


@cli.group()
def service():
    """Manage the live BitChat harness service."""


@service.command("start")
@click.pass_context
def service_start(ctx: click.Context):
    emit([get_service_manager(ctx).start()], ctx.obj["as_json"])


@service.command("status")
@click.pass_context
def service_status(ctx: click.Context):
    emit([get_service_manager(ctx).status()], ctx.obj["as_json"])


@service.command("stop")
@click.pass_context
def service_stop(ctx: click.Context):
    emit([get_service_manager(ctx).stop()], ctx.obj["as_json"])


@service.command("logs")
@click.option("--tail", default=80, show_default=True, help="Number of service log lines to show.")
@click.pass_context
def service_logs(ctx: click.Context, tail: int):
    emit(get_service_manager(ctx).logs(tail=tail), ctx.obj["as_json"])


def repl(ctx: click.Context) -> None:
    state = SessionState()
    click.echo("BitChat harness REPL. Type 'help' or 'quit'.", err=True)
    while True:
        try:
            line = input(f"bitchat:{state.current_chat}> ").strip()
        except EOFError:
            click.echo()
            return
        if not line:
            continue
        if line in {"quit", "exit"}:
            return
        if line == "help":
            click.echo("commands: status, peers, chats, send, history, watch --once, command, nickname, use, undo, redo")
            continue
        if line.startswith("use "):
            click.echo(state.select_chat(line.split(maxsplit=1)[1]))
            continue
        if line == "undo":
            click.echo(state.undo())
            continue
        if line == "redo":
            click.echo(state.redo())
            continue
        args = shlex.split(line)
        try:
            cli.main(args=args, obj=ctx.obj, standalone_mode=False)
        except Exception as exc:
            click.echo(f"error: {exc}", err=True)


def main(argv: list[str] | None = None) -> None:
    try:
        cli.main(args=argv, prog_name="cli-anything-bitchat")
    except RuntimeError as exc:
        click.echo(json.dumps({"type": "error", "message": str(exc)}), err=False)
        sys.exit(1)
