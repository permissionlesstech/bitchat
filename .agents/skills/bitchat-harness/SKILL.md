---
name: bitchat-harness
description: Operate the local BitChat CLI-Anything harness for status, peers, chats, live sends, service start/stop/logs, command parsing, nickname management, history, and watch workflows. Use when the user asks an agent to inspect or drive BitChat through the local harness.
disable-model-invocation: true
license: MIT
compatibility: Requires macOS, a local BitChat checkout, and the uv-installed editable cli-anything-bitchat harness.
allowed-tools: Bash(cli-anything-bitchat *)
argument-hint: "[bitchat harness request]"
---

# BitChat Harness

Use this skill to operate the local BitChat CLI-Anything harness from an agent such as Claude Code or Codex.

The stable command for agents is:

```bash
cli-anything-bitchat --json status
```

The global executable is installed by `uv tool` from the local editable harness package:

```bash
uv tool install -e agent-harness --force
```

The repo-local wrapper at `./.agents/skills/bitchat-harness/scripts/bitchat-harness` is kept only as a fallback for local compatibility.

`service start` builds and launches the harness app bundle in Release by default so it joins the same mainnet BLE mesh as normal phone builds. To intentionally test against Debug/testnet peers, prefix commands with `BITCHAT_HARNESS_CONFIGURATION=debug`.

`service start` also launches a localhost-only read-only PWA web chat. Use `web_url` from the JSON emitted by `service start` or `service status` to open it manually. `service stop` shuts down both the live BitChat service and the web app.

If the harness is not installed or has drifted, refresh it with:

```bash
uv tool install -e agent-harness --force
```

## Command Surface

Prefer `--json` for all agent-readable calls.

```bash
cli-anything-bitchat --json status
cli-anything-bitchat --json peers
cli-anything-bitchat --json chats
cli-anything-bitchat --json send --text "hello mesh"
cli-anything-bitchat --json send --to alice --text "private hello"
cli-anything-bitchat --json command "/who"
cli-anything-bitchat --json nickname get
cli-anything-bitchat --json nickname set agent
cli-anything-bitchat --json history --chat-id mesh --limit 20
cli-anything-bitchat --json watch --once
cli-anything-bitchat --json service start
cli-anything-bitchat --json service status
cli-anything-bitchat --json service logs --tail 40
cli-anything-bitchat --json service stop
```

## Live Chat

For live Bluetooth mesh chat, start the service first:

```bash
cli-anything-bitchat --json service start
```

Then force the live backend for operations that should go through the running mesh service:

```bash
cli-anything-bitchat --json --backend live status
cli-anything-bitchat --json --backend live peers
cli-anything-bitchat --json --backend live command "/who"
cli-anything-bitchat --json --backend live send --text "hello mesh"
```

`--backend auto` uses the live service when it is running and falls back to the short-lived native harness when it is stopped.

For public mesh chat, do not require `peers` or `/who` to show another peer before sending. A public `send --text ...` broadcasts through the live Bluetooth mesh service when Bluetooth is powered on. An empty peer list only means no nearby BitChat peers have been discovered by this Mac yet.

Only direct/private sends require a discovered peer:

```bash
cli-anything-bitchat --json --backend live send --to alice --text "private hello"
```

Invoking the command with no subcommand starts the harness REPL:

```bash
cli-anything-bitchat
```

## Output Contract

The harness emits newline-delimited JSON with objects such as:

```json
{"active_channel":"mesh","backend_mode":"harness","connected_peer_count":0,"message_count":0,"my_peer_id":"...","nickname":"...","type":"status"}
{"backend_mode":"live","status":"running","type":"service","web_status":"running","web_url":"http://127.0.0.1:56789"}
{"chat_id":"mesh","delivery":"harness-observed","sender":"...","text":"hello","type":"message"}
{"backend_mode":"live","delivery":"live-submitted","sender":"...","text":"hello","type":"message"}
```

Treat `type` as the primary discriminator. Common values are `status`, `peer`, `chat`, `message`, `event`, and `error`.

## Important Limitation

The `harness` backend is a short-lived native helper. A `send` result with `delivery=harness-observed` means the harness recorded the operation and exercised BitChat-native command parsing. It does not prove live Bluetooth mesh or Nostr relay delivery.

The `live` backend submits through the Bluetooth mesh service and reports `delivery=live-submitted`. Treat that as accepted by the local live service, not proof that another peer received it.

If `--backend live status` reports `bluetooth_state` as `CBManagerState(rawValue: 5)`, the local live service is Bluetooth-ready. If it also reports `connected_peer_count: 0`, say "no nearby Bluetooth peers discovered yet" rather than "live chat is unavailable"; public mesh broadcasts can still be submitted.

Use `bluetooth_service_uuid` in live `status` to confirm which mesh is active. Mainnet/Release is `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`; Debug/testnet is `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A`.
