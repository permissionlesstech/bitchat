# cli-anything-bitchat

BitChat CLI-Anything harness with an imsg-inspired surface.

## Install

```bash
pip install -e agent-harness
```

## Examples

```bash
cli-anything-bitchat --json status
cli-anything-bitchat --json peers
cli-anything-bitchat send --text "hello mesh"
cli-anything-bitchat send --to alice --text "private hello"
cli-anything-bitchat command "/who"
cli-anything-bitchat history --chat-id mesh --limit 20 --json
cli-anything-bitchat watch --once --json
cli-anything-bitchat --json service start
cli-anything-bitchat --json --backend live status
cli-anything-bitchat --json --backend live command "/who"
cli-anything-bitchat --json --backend live send --text "hello live mesh"
cli-anything-bitchat --json service stop
```

`history` is harness-local JSONL history. BitChat itself is ephemeral and does
not expose a durable chat database like Messages.app.

`--backend auto` uses the live service when `service start` is running and falls
back to the short-lived native harness otherwise. The short-lived harness reports
`delivery=harness-observed`. The live service reports `delivery=live-submitted`,
which means the local live Bluetooth service accepted the message for send; it is
not a remote delivery receipt.

`service start` builds the signed app bundle in Release by default so it joins
the same mainnet BLE mesh as normal phone builds. Set
`BITCHAT_HARNESS_CONFIGURATION=debug` only when intentionally testing against
Debug/testnet peers. Live `status` includes `bluetooth_service_uuid` so agents can
verify the active mesh UUID.

Public live mesh sends do not require `peers` or `/who` to show another peer
first. An empty peer list means this Mac has not discovered a nearby BitChat peer
yet; direct/private sends still require a discovered peer nickname or id.
