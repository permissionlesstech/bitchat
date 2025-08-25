import Foundation

/// Centralized knobs for transport- and UI-related limits.
/// Keep values aligned with existing behavior when replacing magic numbers.
enum TransportConfig {
    // BLE / Protocol
    static let bleDefaultFragmentSize: Int = 469            // ~512 MTU minus protocol overhead
    static let messageTTLDefault: UInt8 = 7                 // Default TTL for mesh flooding
    static let bleMaxInFlightAssemblies: Int = 128          // Cap concurrent fragment assemblies
    static let bleHighDegreeThreshold: Int = 6              // For adaptive TTL/probabilistic relays

    // UI / Storage Caps
    static let privateChatCap: Int = 1337
    static let meshTimelineCap: Int = 1337
    static let geoTimelineCap: Int = 1337
    static let contentLRUCap: Int = 2000

    // Timers
    static let networkResetGraceSeconds: TimeInterval = 600 // 10 minutes
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
    static let blePendingNotificationsCapCount: Int = 20

    // Nostr
    static let nostrReadAckInterval: TimeInterval = 0.35 // ~3 per second

    // UI thresholds
    static let uiLateInsertThreshold: TimeInterval = 15.0
    static let uiProcessedNostrEventsCap: Int = 2000
    static let uiChannelInactivityThresholdSeconds: TimeInterval = 9 * 60
    
    // UI rate limiters (token buckets)
    static let uiSenderRateBucketCapacity: Double = 5
    static let uiSenderRateBucketRefillPerSec: Double = 1.0
    static let uiContentRateBucketCapacity: Double = 3
    static let uiContentRateBucketRefillPerSec: Double = 0.5

    // UI sleeps/delays
    static let uiStartupInitialDelaySeconds: TimeInterval = 1.0
    static let uiStartupShortSleepNs: UInt64 = 200_000_000
    static let uiStartupPhaseDurationSeconds: TimeInterval = 2.0
    static let uiAsyncShortSleepNs: UInt64 = 100_000_000
    static let uiAsyncMediumSleepNs: UInt64 = 500_000_000
    static let uiReadReceiptRetryShortSeconds: TimeInterval = 0.1
    static let uiReadReceiptRetryLongSeconds: TimeInterval = 0.5
    static let uiBatchDispatchStaggerSeconds: TimeInterval = 0.15
    static let uiScrollThrottleSeconds: TimeInterval = 0.5
    static let uiAnimationShortSeconds: TimeInterval = 0.15
    static let uiAnimationMediumSeconds: TimeInterval = 0.2
    static let uiAnimationSidebarSeconds: TimeInterval = 0.25
    static let uiRecentCutoffFiveMinutesSeconds: TimeInterval = 5 * 60

    // BLE maintenance & thresholds
    static let bleMaintenanceInterval: TimeInterval = 10.0
    static let bleMaintenanceLeewaySeconds: Int = 1
    static let bleIsolationRelaxThresholdSeconds: TimeInterval = 60
    static let bleRecentTimeoutWindowSeconds: TimeInterval = 60
    static let bleRecentTimeoutCountThreshold: Int = 3
    static let bleRSSIIsolatedBase: Int = -90
    static let bleRSSIIsolatedRelaxed: Int = -92
    static let bleRSSIConnectedThreshold: Int = -85
    static let bleRSSIHighTimeoutThreshold: Int = -80
    static let blePeerInactivityTimeoutSeconds: TimeInterval = 20.0
    static let bleFragmentLifetimeSeconds: TimeInterval = 30.0
    static let bleIngressRecordLifetimeSeconds: TimeInterval = 3.0
    static let bleConnectTimeoutBackoffWindowSeconds: TimeInterval = 120.0
    static let bleRecentPacketWindowSeconds: TimeInterval = 30.0
    static let bleRecentPacketWindowMaxCount: Int = 100
    static let bleThreadSleepWriteShortDelaySeconds: TimeInterval = 0.05
    static let bleExpectedWritePerFragmentMs: Int = 8
    static let bleExpectedWriteMaxMs: Int = 2000
    static let bleFragmentSpacingMs: Int = 6
    static let bleAnnounceIntervalSeconds: TimeInterval = 10.0
    static let bleDutyOnDurationDense: TimeInterval = 3.0
    static let bleDutyOffDurationDense: TimeInterval = 15.0
    static let bleConnectedAnnounceBaseSecondsDense: TimeInterval = 90.0
    static let bleConnectedAnnounceBaseSecondsSparse: TimeInterval = 45.0
    static let bleConnectedAnnounceJitterDense: TimeInterval = 20.0
    static let bleConnectedAnnounceJitterSparse: TimeInterval = 7.5

    // Location
    static let locationDistanceFilterMeters: Double = 1000
    static let locationLiveRefreshInterval: TimeInterval = 5.0

    // Nostr geohash
    static let nostrGeohashInitialLookbackSeconds: TimeInterval = 3600
    static let nostrGeohashInitialLimit: Int = 200
    static let nostrGeoRelayCount: Int = 5
    static let nostrGeohashSampleLookbackSeconds: TimeInterval = 300
    static let nostrGeohashSampleLimit: Int = 100
    static let nostrDMSubscribeLookbackSeconds: TimeInterval = 86400

    // Nostr helpers
    static let nostrShortKeyDisplayLength: Int = 8
    static let nostrConvKeyPrefixLength: Int = 16

    // Compression
    static let compressionThresholdBytes: Int = 100

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
    static let nostrRelayDefaultFetchLimit: Int = 100

    // Geo relay directory
    static let geoRelayFetchIntervalSeconds: TimeInterval = 60 * 60 * 24

    // BLE operational delays
    static let bleInitialAnnounceDelaySeconds: TimeInterval = 2.0
    static let bleConnectTimeoutSeconds: TimeInterval = 8.0
    static let bleRestartScanDelaySeconds: TimeInterval = 0.1
    static let blePostSubscribeAnnounceDelaySeconds: TimeInterval = 0.1
    static let blePostAnnounceDelaySeconds: TimeInterval = 0.4
    static let bleForceAnnounceMinIntervalSeconds: TimeInterval = 0.2

    // Content hashing / formatting
    static let contentKeyPrefixLength: Int = 256
    static let uiLongMessageLengthThreshold: Int = 2000
    static let uiVeryLongTokenThreshold: Int = 512
    static let uiLongMessageLineLimit: Int = 30
    static let uiFingerprintSampleCount: Int = 3
    
    // UI swipe/gesture thresholds
    static let uiBackSwipeTranslationLarge: CGFloat = 50
    static let uiBackSwipeTranslationSmall: CGFloat = 30
    static let uiBackSwipeVelocityThreshold: CGFloat = 300
    
    // UI color tuning
    static let uiColorHueAvoidanceDelta: Double = 0.05
    static let uiColorHueOffset: Double = 0.12

    // UI windowing (infinite scroll)
    static let uiWindowInitialCountPublic: Int = 300
    static let uiWindowInitialCountPrivate: Int = 300
    static let uiWindowStepCount: Int = 200

    // Share extension
    static let uiShareExtensionDismissDelaySeconds: TimeInterval = 0.3
    static let uiShareAcceptWindowSeconds: TimeInterval = 30.0
    static let uiMigrationCutoffSeconds: TimeInterval = 24 * 60 * 60
}
