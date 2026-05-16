BitChat Privacy Assessment
==========================

Scope
- Mesh transport (BLE) behavior and metadata minimization
- Nostr-based private message fallback (gift-wrapped, end-to-end encrypted)
- Read receipts and delivery acknowledgments
- Logging/telemetry posture and controls

Summary
- No accounts, no servers for mesh; Nostr used only for mutual favorites, with end-to-end Noise encryption encapsulated in gift wraps.
- BLE announces contain only nickname and Noise pubkey. No device name, no plaintext identity beyond what the user broadcasts.
- Discovery and flooding incorporate jitter and TTL caps to reduce linkability and propagation radius of encrypted payloads.
- UI and storage remain ephemeral; message content is not persisted to disk. Minimal state (e.g., read-receipt IDs) is stored for UX and is bounded/cleaned.
- Logging defaults to conservative levels; debug verbosity is suppressed for release builds. A single env var can raise/lower threshold when needed.

BLE Privacy Considerations
- Announce content: Unchanged — nickname + Noise public key only.
- Local Name: Not used (explicitly disabled). Avoids leaking device/OS identity.
- Address: iOS uses BLE MAC randomization; BitChat does not attempt to set static addresses.
- Announce jitter: Each announce is delayed by a small random jitter to avoid synchronization-based correlation.
- Scanning: Foreground scanning uses “allow duplicates” briefly to improve discovery latency; background uses standard scanning parameters.
- RSSI gating: The acceptance threshold adapts to nearby density (approx. -95 to -80 dBm) to reduce long-distance observations in dense areas and improve connectivity in sparse ones.
- Fragmentation: Fragments use write-with-response for reliability (less re-broadcast churn = fewer repeated signals).
- GATT permissions: Private characteristic disallows .read; we use notify/write/writeWithoutResponse to avoid exposing plaintext attributes over GATT.

Mesh Routing and Multi-hop Limits
- Encrypted relays permitted with random per-hop delay (small jitter) to smooth floods.
- TTL cap: Encrypted payloads are capped at 2 hops, limiting metadata spread and path reconstruction risk while enabling close-range relays.

Nostr Private Messaging Fallback
- Usage criteria: Only attempted for mutual favorites or where a Nostr key has been exchanged (stored in favorites).
- Payload confidentiality: Messages embed a BitChat Noise-encrypted packet inside a NIP-17 gift wrap; relays see only random-looking ciphertext.
- Timestamp handling: Gift wraps add small randomized offsets to reduce exact timing correlation.
- Read/delivery acks: Also encapsulated in gift wraps, preserving content secrecy and minimizing metadata.
- Relay policy variance: Some relays apply “web-of-trust” policies and may reject events; BitChat tolerates partial delivery and still prefers mesh when available.

Read Receipts and Delivery Acks
- Routing policy: Prefer mesh if Noise session established; otherwise use Nostr when mapping exists.
- Throttling: Nostr READ acks are queued and rate-limited (~3/s) to prevent relay rate limits during backlogs.
- Coalescing (optional future): When entering a chat with many unread, only send READ for the latest message, marking older as read locally to reduce metadata.

Data Retention and State
- Messages: Ephemeral in-memory only; history is bounded per chat and trimmed.
- Read-receipt IDs: Stored in `UserDefaults` for UX continuity; periodically pruned to IDs present in memory.
- Favorites: Noise and optional Nostr keys with petnames; can be wiped via panic action.
- Panic: Triple-tap clears keys, sessions, cached state, and disconnects transports.

Logging and Telemetry
- Centralized `SecureLogger` filters potential secrets and uses OSLog privacy markers.
- Default level: `info`; release builds suppress debug. Developers can set `BITCHAT_LOG_LEVEL=debug|info|warning|error|fault`.
- Transport routing, ACK sends, subscribe/connect noise were downgraded from info→debug.
- OS/system errors (e.g., transient WebSocket disconnects) may still appear in system logs; BitChat avoids re-logging those unless actionable.

Residual Risks and Mitigations
- RF fingerprinting: BLE presence is observable at the RF layer; mitigated by minimal announce content and platform MAC randomization.
- Timing correlation: Announce/relay jitter reduces but does not eliminate timing analysis. Avoids synchronized bursts.
- Relay metadata: Nostr relays can see that an account posts gift wraps; content remains end-to-end encrypted. Favor mesh path when in range.

Recommendations (Next)
- Add optional coalesced READ behavior for large backlogs.
- Expose a “low-visibility mode” to reduce scanning aggressiveness in sensitive contexts.
- Allow user-configurable Nostr relay set with a “private relays only” toggle.

