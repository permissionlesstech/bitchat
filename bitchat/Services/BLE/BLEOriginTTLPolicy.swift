//
// BLEOriginTTLPolicy.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

/// Chooses the TTL a locally originated public broadcast leaves with.
///
/// Split out from `BLEService` so the choice is testable without a radio, and so
/// the reasoning lives in one place: see
/// `TransportConfig.broadcastOriginTTLRange` for why originating at a fixed
/// maximum identifies the author to any direct listener.
enum BLEOriginTTLPolicy {
    /// Uniform draw from the configured range.
    ///
    /// The randomizer is injectable so tests can pin the value; production uses
    /// the system generator. Note that TTL is excluded from the packet signature
    /// (`toBinaryDataForSigning` zeroes it so relays can decrement without
    /// invalidating), so varying it per message is signature-safe and needs no
    /// cross-platform agreement — a peer running any version simply sees a
    /// smaller starting TTL and relays it normally.
    static func originTTL(
        range: ClosedRange<UInt8> = TransportConfig.broadcastOriginTTLRange,
        randomTTL: (ClosedRange<UInt8>) -> UInt8 = { UInt8.random(in: $0) }
    ) -> UInt8 {
        // A degenerate or inverted range must not trap; fall back to the
        // documented default rather than crashing a send path.
        guard range.lowerBound <= range.upperBound, range.lowerBound >= 1 else {
            return TransportConfig.messageTTLDefault
        }
        return randomTTL(range)
    }

    /// Gap after which the next voice frame counts as a new talk burst.
    static let voiceBurstGap: TimeInterval = 1.0

    /// TTL for a live-voice frame: one draw per talk burst, not per frame.
    ///
    /// This distinction is the whole value. Voice leaves at roughly 15 frames a
    /// second, so drawing per frame would hand an observer the maximum of the
    /// range within a fraction of a second — averaging over a burst would
    /// defeat the randomisation completely and cost reach for nothing. One draw
    /// per burst makes a burst a single sample, the same as a text message.
    ///
    /// Returns the TTL to use and the burst TTL to remember. A burst ends when
    /// `voiceBurstGap` passes with no frame.
    static func voiceBurstTTL(
        now: Date,
        lastFrameAt: Date?,
        currentBurstTTL: UInt8?,
        burstGap: TimeInterval = voiceBurstGap,
        range: ClosedRange<UInt8> = TransportConfig.broadcastOriginTTLRange,
        randomTTL: (ClosedRange<UInt8>) -> UInt8 = { UInt8.random(in: $0) }
    ) -> UInt8 {
        if let currentBurstTTL,
           let lastFrameAt,
           now.timeIntervalSince(lastFrameAt) < burstGap {
            return currentBurstTTL
        }
        return originTTL(range: range, randomTTL: randomTTL)
    }
}
