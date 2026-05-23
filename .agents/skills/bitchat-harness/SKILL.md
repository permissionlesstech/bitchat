---
name: bitchat-harness
description: Operate the local BitChat CLI-Anything harness for status, peers, chats, live sends, service start/stop/logs, command parsing, nickname management, history, and watch workflows. Use when the user asks an agent to inspect or drive BitChat through the local harness.
disable-model-invocation: true
license: MIT
compatibility: Requires macOS, a local BitChat checkout, and the editable cli-anything-bitchat harness install.
allowed-tools: Bash(./.agents/skills/bitchat-harness/scripts/bitchat-harness *)
argument-hint: "[bitchat harness request]"
---

# BitChat Harness

Use this skill to operate the local BitChat CLI-Anything harness from an agent such as Claude Code or Codex.

The stable command for agents is:

```bash
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json status
```

The wrapper runs from the BitChat repo and delegates to:

```bash
cli-anything-bitchat
```

`service start` builds and launches the harness app bundle in Release by default so it joins the same mainnet BLE mesh as normal phone builds. To intentionally test against Debug/testnet peers, prefix commands with `BITCHAT_HARNESS_CONFIGURATION=debug`.

If the harness is not installed or has drifted, refresh it with:

```bash
python3 -m pip install -e agent-harness
```

## Command Surface

Prefer `--json` for all agent-readable calls.

```bash
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json status
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json peers
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json chats
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json send --text "hello mesh"
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json send --to alice --text "private hello"
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json command "/who"
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json nickname get
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json nickname set agent
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json history --chat-id mesh --limit 20
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json watch --once
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json service start
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json service status
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json service logs --tail 40
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json service stop
```

## Live Chat

For live Bluetooth mesh chat, start the service first:

```bash
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json service start
```

Then force the live backend for operations that should go through the running mesh service:

```bash
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json --backend live status
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json --backend live peers
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json --backend live command "/who"
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json --backend live send --text "hello mesh"
```

`--backend auto` uses the live service when it is running and falls back to the short-lived native harness when it is stopped.

For public mesh chat, do not require `peers` or `/who` to show another peer before sending. A public `send --text ...` broadcasts through the live Bluetooth mesh service when Bluetooth is powered on. An empty peer list only means no nearby BitChat peers have been discovered by this Mac yet.

Only direct/private sends require a discovered peer:

```bash
./.agents/skills/bitchat-harness/scripts/bitchat-harness --json --backend live send --to alice --text "private hello"
```

Invoking the wrapper with no subcommand starts the harness REPL:

```bash
./.agents/skills/bitchat-harness/scripts/bitchat-harness
```

## Output Contract

The harness emits newline-delimited JSON with objects such as:

```json
{"active_channel":"mesh","backend_mode":"harness","connected_peer_count":0,"message_count":0,"my_peer_id":"...","nickname":"...","type":"status"}
{"chat_id":"mesh","delivery":"harness-observed","sender":"...","text":"hello","type":"message"}
{"backend_mode":"live","delivery":"live-submitted","sender":"...","text":"hello","type":"message"}
```

Treat `type` as the primary discriminator. Common values are `status`, `peer`, `chat`, `message`, `event`, and `error`.

## Important Limitation

The `harness` backend is a short-lived native helper. A `send` result with `delivery=harness-observed` means the harness recorded the operation and exercised BitChat-native command parsing. It does not prove live Bluetooth mesh or Nostr relay delivery.

The `live` backend submits through the Bluetooth mesh service and reports `delivery=live-submitted`. Treat that as accepted by the local live service, not proof that another peer received it.

If `--backend live status` reports `bluetooth_state` as `CBManagerState(rawValue: 5)`, the local live service is Bluetooth-ready. If it also reports `connected_peer_count: 0`, say "no nearby Bluetooth peers discovered yet" rather than "live chat is unavailable"; public mesh broadcasts can still be submitted.

Use `bluetooth_service_uuid` in live `status` to confirm which mesh is active. Mainnet/Release is `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C`; Debug/testnet is `F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A`.
