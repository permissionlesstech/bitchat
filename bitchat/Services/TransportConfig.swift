import Foundation

/// Centralized knobs for transport- and UI-related limits.
/// Keep values aligned with existing behavior when replacing magic numbers.
enum TransportConfig {
    // BLE / Protocol
    static let bleDefaultFragmentSize: Int = 469            // ~512 MTU minus protocol overhead
    static let messageTTLDefault: UInt8 = 7                 // Default TTL for mesh flooding
    static let bleMaxInFlightAssemblies: Int = 128          // Cap concurrent fragment assemblies
    static let bleHighDegreeThreshold: Int = 6              // For adaptive TTL/probabilistic relays
    static let bleMaxConcurrentTransfers: Int = 2           // Limit simultaneous large media sends
    static let bleFragmentRelayMinDelayMs: Int = 8          // Faster forwarding for media fragments
    static let bleFragmentRelayMaxDelayMs: Int = 25         // Upper jitter bound for fragment relays
    // Fragment relay TTL in sparse graphs; matches messageTTLDefault so media
    // reaches as far as text. Dense graphs clamp harder in RelayController.
    static let bleFragmentRelayTtlCap: UInt8 = 7
    static let bleFragmentRelayTtlCapDense: UInt8 = 5       // Contain fragment floods in dense graphs

    // Live voice (push-to-talk)
    // Burst-content budget per voice packet. Sized so the Noise ciphertext
    // (content + 1 type byte + 16 tag bytes) stays within MessagePadding's
    // 256-byte bucket and the whole directed packet (16 header + 8 sender +
    // 8 recipient + 256 payload = 288 bytes) rides one BLE frame — live audio
    // must never enter the fragment scheduler, which caps concurrent
    // transfers at 2 and would let voice starve file sends.
    static let pttMaxBurstContentBytes: Int = 210
    static let pttJitterBufferSeconds: TimeInterval = 0.35  // buffered audio before live playback starts
    static let pttJitterDeadlineSeconds: TimeInterval = 0.5 // start anyway after this wall-clock wait
    static let pttBurstEndTimeoutSeconds: TimeInterval = 3.0 // no frames -> burst considered ended
    static let pttMaxConcurrentAssemblies: Int = 8          // concurrent inbound bursts cap
    static let pttMaxBurstBytes: Int = 384 * 1024           // 120s at ~2KB/s + generous slack
    static let pttFinishedBurstRegistrySeconds: TimeInterval = 600 // window to absorb the finalized note
    // Inbound flood guard: a real burst arrives at ~2KB/s; allow 3x plus a
    // small settling allowance before dropping a sender's frames.
    static let pttInboundMaxBytesPerSecond: Int = 6_000
    // Public bursts are live-only traffic: frames older than this are relay
    // stragglers or replays, not audio anyone should start hearing.
    static let pttPublicFrameMaxAgeSeconds: TimeInterval = 30

    // Mesh diagnostics (/ping)
    static let meshPingTimeoutSeconds: TimeInterval = 10    // Give up on a probe after this window
    static let meshPingInboundMaxPerLink: Int = 5           // Inbound ping budget per ingress link (claimed sender is spoofable)...
    static let meshPingInboundWindowSeconds: TimeInterval = 10 // ...per sliding window (anti-amplification)

    // UI / Storage Caps
    static let privateChatCap: Int = 1337
    static let meshTimelineCap: Int = 1337
    static let geoTimelineCap: Int = 1337
    static let contentLRUCap: Int = 2000
    static let geoSamplingEventLRUCap: Int = 2000

    // Timers
    static let networkResetGraceSeconds: TimeInterval = 600 // 10 minutes
    static let networkNotificationCooldownSeconds: TimeInterval = 300 // 5 minutes
    static let basePublicFlushInterval: TimeInterval = 0.08  // ~12.5 fps batching

    // BLE duty/announce/connect
    static let bleConnectRateLimitInterval: TimeInterval = 0.5
    static let bleMaxCentralLinks: Int = 6
    static let bleDutyOnDuration: TimeInterval = 5.0
    static let bleDutyOffDuration: TimeInterval = 10.0
    static let bleAnnounceMinInterval: TimeInterval = 1.0

    // BLE discovery/quality thresholds
    static let bleDynamicRSSIThresholdDefault: Int = -90
    static let bleConnectionCandidatesMax: Int = 100
    static let blePendingWriteBufferCapBytes: Int = 1_000_000
    static let bleNotificationAssemblerHardCapBytes: Int = 8 * 1024 * 1024
    static let bleAssemblerStallResetMs: Int = 250
    static let blePendingNotificationsCapCount: Int = 128
    static let bleNotificationRetryDelayMs: Int = 25
    static let bleNotificationRetryMaxAttempts: Int = 80
    // Sample interval for notification backpressure logs (fire per fragment
    // during media transfers).
    static let bleBackpressureLogInterval: Int = 25

    // Nostr
    static let nostrReadAckInterval: TimeInterval = 0.35 // ~3 per second
    static let nostrInboundEventDedupCap: Int = 4096
    static let nostrInboundEventDedupTrimTarget: Int = 3072
    static let nostrDuplicateEventLogInterval: Int = 50
    // Sample interval for per-event debug logs on the inbound hot path.
    static let nostrInboundEventLogInterval: Int = 100

    // Conversation store diagnostics (field observability)
    // Sample interval for the periodic store-audit "OK" heartbeat line
    // (first + every Nth audit); violations always log at error level.
    static let conversationStoreAuditLogInterval: Int = 10
    // Sample interval for the mirrored-republish debug line in the ID-only
    // delivery fan-out (first + every Nth republish).
    static let conversationStoreMirroredRepublishLogInterval: Int = 25

    // UI thresholds
    static let uiProcessedNostrEventsCap: Int = 2000

    // UI rate limiters (token buckets)
    static let uiSenderRateBucketCapacity: Double = 5
    static let uiSenderRateBucketRefillPerSec: Double = 1.0
    static let uiContentRateBucketCapacity: Double = 3
    static let uiContentRateBucketRefillPerSec: Double = 0.5

    // UI sleeps/delays
    static let uiStartupInitialDelaySeconds: TimeInterval = 1.0
    static let uiStartupPhaseDurationSeconds: TimeInterval = 2.0
    static let uiAsyncShortSleepNs: UInt64 = 100_000_000
    static let uiReadReceiptRetryShortSeconds: TimeInterval = 0.1
    static let uiReadReceiptRetryLongSeconds: TimeInterval = 0.5
    static let uiBatchDispatchStaggerSeconds: TimeInterval = 0.15
    static let uiScrollThrottleSeconds: TimeInterval = 0.5
    static let uiAnimationMediumSeconds: TimeInterval = 0.2
    static let uiRecentCutoffFiveMinutesSeconds: TimeInterval = 5 * 60
    static let uiMeshEmptyConfirmationSeconds: TimeInterval = 30.0

    // BLE maintenance & thresholds
    static let bleMaintenanceInterval: TimeInterval = 5.0
    static let bleMaintenanceLeewaySeconds: Int = 1
    static let bleIsolationRelaxThresholdSeconds: TimeInterval = 30
    // Isolated nodes accept the weakest usable links — a fringe connection
    // beats no connection. Relaxed floor sits at CoreBluetooth's practical
    // reporting limit so prolonged isolation gates on nothing but decode.
    static let bleRSSIIsolatedBase: Int = -95
    static let bleRSSIIsolatedRelaxed: Int = -100
    static let bleRSSIConnectedThreshold: Int = -85
    // How long without seeing traffic before we sanity-check the direct link
    // Lowered to make connected→reachable icon changes react faster when walking out of range
    static let blePeerInactivityTimeoutSeconds: TimeInterval = 8.0
    // How long to retain a peer as "reachable" (not directly connected) since lastSeen.
    // Must comfortably exceed the worst-case dense announce interval (38s) plus a
    // missed cycle, so duty-cycled nodes don't forget peers between announces.
    static let bleReachabilityRetentionVerifiedSeconds: TimeInterval = 60.0    // verified/favorites
    static let bleReachabilityRetentionUnverifiedSeconds: TimeInterval = 45.0  // unknown/unverified
    static let bleFragmentLifetimeSeconds: TimeInterval = 30.0
    static let bleIngressRecordLifetimeSeconds: TimeInterval = 3.0
    // At most one rotation rebind per link per window: TTL is not signed, so
    // a replayed announce can forge "direct", and without a cooldown two
    // identities could fight over a link in a rebind flip-flop.
    static let bleLinkRebindCooldownSeconds: TimeInterval = 60.0
    static let bleConnectTimeoutBackoffWindowSeconds: TimeInterval = 120.0
    static let bleRecentPacketWindowSeconds: TimeInterval = 30.0
    static let bleRecentPacketWindowMaxCount: Int = 100
    // Keep scanning fully ON when we saw traffic very recently
    static let bleRecentTrafficForceScanSeconds: TimeInterval = 10.0
    static let bleThreadSleepWriteShortDelaySeconds: TimeInterval = 0.05
    static let bleExpectedWritePerFragmentMs: Int = 20
    static let bleExpectedWriteMaxMs: Int = 5000
    // Fragment pacing: Conservative spacing to prevent BLE buffer overflow
    // Aggressive pacing causes packet loss; needs 25-30ms between fragments for reliable delivery
    static let bleFragmentSpacingMs: Int = 30
    static let bleFragmentSpacingDirectedMs: Int = 25
    static let bleAnnounceIntervalSeconds: TimeInterval = 4.0
    static let bleDutyOnDurationDense: TimeInterval = 3.0
    static let bleDutyOffDurationDense: TimeInterval = 15.0
    static let bleConnectedAnnounceBaseSecondsDense: TimeInterval = 30.0
    static let bleConnectedAnnounceBaseSecondsSparse: TimeInterval = 15.0
    static let bleConnectedAnnounceJitterDense: TimeInterval = 8.0
    static let bleConnectedAnnounceJitterSparse: TimeInterval = 4.0

    // Location
    static let locationDistanceFilterMeters: Double = 1000
    // Live (channel sheet open) distance threshold for meaningful updates
    static let locationDistanceFilterLiveMeters: Double = 10.0
    static let locationLiveRefreshInterval: TimeInterval = 5.0

    // Notifications (geohash)
    static let uiGeoNotifyCooldownSeconds: TimeInterval = 60.0
    static let uiGeoNotifySnippetMaxLen: Int = 80

    // Nostr geohash
    static let nostrGeohashInitialLookbackSeconds: TimeInterval = 3600
    static let nostrGeohashInitialLimit: Int = 200
    static let nostrGeoRelayCount: Int = 5
    static let nostrGeohashSampleLookbackSeconds: TimeInterval = 300
    static let nostrGeohashSampleLimit: Int = 100
    static let nostrDMSubscribeLookbackSeconds: TimeInterval = 86400
    // A sampled chat message this recent means "a conversation is happening
    // there" for the empty-timeline nearby-activity hint.
    static let uiGeohashChatActivityWindowSeconds: TimeInterval = 900
    // Startup delay before reading the gossip archive for "heard here
    // earlier" echoes; covers the archive's async disk restore.
    static let uiArchivedEchoLoadDelaySeconds: TimeInterval = 1.5
    // Dead drops: location notes left via /drop expire after this long.
    static let locationDropExpirySeconds: TimeInterval = 24 * 60 * 60
    // Poll cadence while geo notes wait for a relay connection (Tor warming
    // up); re-subscribes as soon as one comes up.
    static let uiGeoNotesConnectivityRetrySeconds: TimeInterval = 3.0

    // Message deduplication
    static let messageDedupMaxAgeSeconds: TimeInterval = 300
    static let messageDedupMaxCount: Int = 1000

    // Verification QR
    static let verificationQRMaxAgeSeconds: TimeInterval = 5 * 60

    // Nostr relay backoff
    static let nostrRelayInitialBackoffSeconds: TimeInterval = 1.0
    static let nostrRelayMaxBackoffSeconds: TimeInterval = 300.0
    static let nostrRelayBackoffMultiplier: Double = 2.0
    static let nostrRelayMaxReconnectAttempts: Int = 10
    // Reconnect delays get ±20% random jitter so relays that dropped together
    // (e.g. a network blip) don't thundering-herd the same reconnect instant.
    static let nostrRelayBackoffJitterRatio: Double = 0.2
    static let nostrRelayDefaultFetchLimit: Int = 100
    // How many consecutive Tor-readiness waits (each bounded by TorManager's
    // bootstrap deadline) to attempt before unblocking pending EOSE callers.
    static let nostrTorReadyMaxWaitAttempts: Int = 3
    static let nostrPendingSendQueueCap: Int = 200
    // Sample interval for the send-queue overflow warning (first + every Nth
    // dropped event). Drops are ephemeral presence/geo traffic — log-only.
    static let nostrPendingSendDropLogInterval: Int = 10
    // Pending (not-yet-flushed) REQs are bounded per relay: oldest-by-insertion
    // eviction at the cap, plus an age sweep on connect attempts. Durable
    // subscription intent survives in subscriptionRequestState either way.
    static let nostrPendingSubscriptionsPerRelayCap: Int = 64
    static let nostrPendingSubscriptionTTLSeconds: TimeInterval = 600.0
    // Fallback deadline for treating a subscription's initial fetch as complete
    // when a relay never sends EOSE (generous to cover Tor circuit setup).
    static let nostrSubscriptionEOSEFallbackSeconds: TimeInterval = 10.0
    // A bridge drop is durable only after NIP-20 OK. Relays that omit OK must
    // not pin the router's in-flight state indefinitely.
    static let nostrConfirmedSendAckTimeoutSeconds: TimeInterval = 10.0
    // After this long, a relay marked permanently failed gets another chance.
    static let nostrRelayFailureCooldownSeconds: TimeInterval = 600.0

    // Geo relay directory
    static let geoRelayFetchIntervalSeconds: TimeInterval = 60 * 60 * 24
    static let geoRelayRefreshCheckIntervalSeconds: TimeInterval = 60 * 60
    static let geoRelayRetryInitialSeconds: TimeInterval = 60
    static let geoRelayRetryMaxSeconds: TimeInterval = 60 * 60

    // BLE operational delays
    static let bleInitialAnnounceDelaySeconds: TimeInterval = 0.6
    static let bleConnectTimeoutSeconds: TimeInterval = 8.0
    static let bleRestartScanDelaySeconds: TimeInterval = 0.1
    static let blePostSubscribeAnnounceDelaySeconds: TimeInterval = 0.05
    static let blePostAnnounceDelaySeconds: TimeInterval = 0.4
    static let bleForceAnnounceMinIntervalSeconds: TimeInterval = 0.15

    // BCH-01-004: Rate-limiting for subscription-triggered announces
    // Prevents rapid enumeration attacks by rate-limiting announce responses
    static let bleSubscriptionRateLimitMinSeconds: TimeInterval = 2.0       // Minimum interval between announces per central
    static let bleSubscriptionRateLimitBackoffFactor: Double = 2.0          // Exponential backoff multiplier
    static let bleSubscriptionRateLimitMaxBackoffSeconds: TimeInterval = 30.0  // Maximum backoff period
    static let bleSubscriptionRateLimitWindowSeconds: TimeInterval = 60.0   // Window for tracking subscription attempts
    static let bleSubscriptionRateLimitMaxAttempts: Int = 5                 // Max attempts before extended cooldown

    // Source routing (v2 directed packets)
    // Longest path we will originate, in intermediate hops between us and the
    // recipient. Keep small: every hop must be a fresh, confirmed, v2-capable
    // node, and long stale paths fail more often than floods.
    static let bleSourceRouteMaxIntermediateHops: Int = 4
    // A routed send with no inbound traffic from the recipient within this
    // window counts as a route failure.
    static let bleSourceRouteConfirmationWindowSeconds: TimeInterval = 10.0
    // After a route failure, directed sends to that recipient flood instead
    // of routing until this lapses.
    static let bleSourceRouteSuppressionSeconds: TimeInterval = 60.0

    // Targeted fragment resync (REQUEST_SYNC fragmentIdFilter)
    // A broadcast reassembly with no new fragment for this long is stalled
    // and triggers a targeted REQUEST_SYNC naming its fragment stream.
    static let bleFragmentResyncStallSeconds: TimeInterval = 5.0
    // Minimum spacing between targeted resync requests for the same stream.
    static let bleFragmentResyncRetrySeconds: TimeInterval = 10.0

    // Store-and-forward for directed packets at relays. Spooled packets retry
    // on each maintenance flush until the window lapses; a longer window lets
    // brief link gaps (walking between rooms, reconnect churn) heal themselves.
    static let bleDirectedSpoolWindowSeconds: TimeInterval = 60.0

    // Log/UI debounce windows
    // Shorter debounce so UI reacts faster while still suppressing duplicate callbacks
    static let bleDisconnectNotifyDebounceSeconds: TimeInterval = 0.9
    static let bleReconnectLogDebounceSeconds: TimeInterval = 2.0

    // Background wake-on-proximity (iOS). Pending connects issued on
    // backgrounding never expire at the OS level: the Bluetooth controller
    // completes them whenever the peer reappears in range and relaunches the
    // app via state restoration. Entries older than the BLE address-rotation
    // window no longer map to a reachable address, so the cache prunes them.
    static let bleRecentPeripheralCacheCap: Int = 16
    static let bleRecentPeripheralMaxAgeSeconds: TimeInterval = 15 * 60
    // Central slots kept free for connects driven by live background discovery
    static let bleBackgroundPendingConnectSlotReserve: Int = 2

    // Weak-link cooldown after connection timeouts
    static let bleWeakLinkCooldownSeconds: TimeInterval = 30.0
    static let bleWeakLinkRSSICutoff: Int = -90
    // Rediscovery ignore windows after a failed link, by failure kind:
    // a connect attempt that timed out means the peer likely isn't reachable,
    // so back off; a dropped established connection (walked out of range)
    // usually returns, so only pause long enough for CoreBluetooth to settle.
    static let bleTimeoutDiscoveryIgnoreSeconds: TimeInterval = 15.0
    static let bleDisconnectDiscoveryIgnoreSeconds: TimeInterval = 3.0

    // Content hashing / formatting
    static let contentKeyPrefixLength: Int = 256
    static let uiLongMessageLengthThreshold: Int = 2000
    static let uiVeryLongTokenThreshold: Int = 512
    static let uiLongMessageLineLimit: Int = 30
    static let uiFingerprintSampleCount: Int = 3

    // UI color tuning
    static let uiColorHueAvoidanceDelta: Double = 0.05
    static let uiColorHueOffset: Double = 0.12
    // Peer list palette
    static let uiPeerPaletteSlots: Int = 36
    static let uiPeerPaletteRingBrightnessDeltaLight: Double = 0.07
    static let uiPeerPaletteRingBrightnessDeltaDark: Double = -0.07

    // UI windowing (infinite scroll)
    static let uiWindowInitialCountPublic: Int = 300
    static let uiWindowInitialCountPrivate: Int = 300
    static let uiWindowStepCount: Int = 200

    // Share extension
    static let uiShareExtensionDismissDelaySeconds: TimeInterval = 2.0
    static let uiShareAcceptWindowSeconds: TimeInterval = 30.0
    static let uiMigrationCutoffSeconds: TimeInterval = 24 * 60 * 60

    // Gossip Sync Configuration
    static let syncSeenCapacity: Int = 1000
    static let syncGCSMaxBytes: Int = 400
    static let syncGCSTargetFpr: Double = 0.01
    // Fragments and file transfers keep the short window; whole public
    // messages get hours so a phone walking between partitions carries the
    // room's recent history with it (see syncPublicMessageMaxAgeSeconds).
    static let syncMaxMessageAgeSeconds: TimeInterval = 900
    // How far back public broadcast messages stay sync-able. Must not exceed
    // the receive-side acceptance window (BLEPublicMessagePolicy uses this
    // same constant) or served packets would be dropped as stale.
    static let syncPublicMessageMaxAgeSeconds: TimeInterval = 6 * 60 * 60
    static let syncMaintenanceIntervalSeconds: TimeInterval = 30.0
    static let syncStalePeerCleanupIntervalSeconds: TimeInterval = 60.0
    static let syncStalePeerTimeoutSeconds: TimeInterval = 60.0
    static let syncFragmentCapacity: Int = 600
    static let syncFileTransferCapacity: Int = 200
    static let syncFragmentIntervalSeconds: TimeInterval = 30.0
    static let syncFileTransferIntervalSeconds: TimeInterval = 60.0
    static let syncMessageIntervalSeconds: TimeInterval = 15.0
    static let syncResponseRateLimitMaxResponses: Int = 8
    static let syncResponseRateLimitWindowSeconds: TimeInterval = 30.0

    // Courier store-and-forward
    // Initial spray-and-wait budget per deposited envelope: each courier may
    // hand half its remaining copies to another courier on encounter, so a
    // message diffuses through a moving crowd instead of riding one person.
    static let courierInitialCopies: UInt8 = 4
    // Cooldown between speculative multi-hop handovers of the same envelope
    // toward a recipient heard only via relayed announces.
    static let courierRemoteHandoverCooldownSeconds: TimeInterval = 10 * 60
    // Recently opened courier inner message IDs kept for receiver-side dedup
    // (redundant copies ride distinct seals, so only the inner ID matches).
    static let courierOpenedMessageIDCap: Int = 512

    // One-time prekey bundles (forward-secret courier sealing)
    // Own gossip-sync round for bundles: modest cadence, bounded peer count,
    // and a long freshness window so bundles persist mesh-wide while their
    // owners are away.
    static let syncPrekeyBundleCapacity: Int = 200
    static let syncPrekeyBundleIntervalSeconds: TimeInterval = 60.0
    static let syncPrekeyBundleMaxAgeSeconds: TimeInterval = 24 * 60 * 60
    // Unforced re-broadcasts of our own (unchanged) bundle, piggybacked on
    // announces, keep it alive in peers' gossip stores; changed bundles are
    // sent immediately.
    static let prekeyBundleRebroadcastSeconds: TimeInterval = 60 * 60
}
