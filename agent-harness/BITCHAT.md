# BitChat Harness Notes

Target software: the local BitChat checkout containing this harness.

The harness follows the CLI-Anything layout and exposes an imsg-like operator
surface for agents:

- one-shot commands for status, peers, chats, send, history, watch, command,
  and nickname management
- default REPL when invoked without a subcommand
- `--json` newline-delimited machine output
- local JSONL history for messages observed or sent through the harness
- `service start/status/stop/logs` for the live Bluetooth mesh service

Short-lived harness operations call the native Swift helper through:

```bash
swift run bitchat -- --harness <command>
```

Live operations start a signed app bundle through LaunchServices, then talk to
the service over localhost:

```bash
cli-anything-bitchat --json service start
cli-anything-bitchat --json --backend live command "/who"
cli-anything-bitchat --json --backend live send --text "hello mesh"
cli-anything-bitchat --json service stop
```

Set `BITCHAT_HARNESS_BINARY` to point at a prebuilt helper executable when a
faster backend is available.

By default, `service start` builds the signed app bundle in Release so it uses
the mainnet BLE service UUID expected by normal phone builds. Use
`BITCHAT_HARNESS_CONFIGURATION=debug` only for Debug/testnet peers. Check
`bluetooth_service_uuid` in live `status` when diagnosing discovery.

Delivery language matters: `delivery=harness-observed` means the short-lived
harness recorded the operation and exercised BitChat-native command parsing.
`delivery=live-submitted` means the local live Bluetooth service accepted the
message for send; it is not a remote delivery receipt from another peer.

Public mesh sends are valid even when `peers` is empty or `/who` says no one is
online. That only means no nearby Bluetooth peer has been discovered yet.
Private sends with `--to` require a discovered peer.
