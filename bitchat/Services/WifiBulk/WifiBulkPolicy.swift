//
// WifiBulkPolicy.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitFoundation
import Foundation

/// Pure eligibility decisions for the Wi-Fi bulk data plane. Anything that
/// fails these gates rides BLE fragmentation exactly as before — the BLE
/// fallback is the common case and must stay bulletproof.
enum WifiBulkPolicy {
    struct SendCandidate {
        let payloadBytes: Int
        let peerCapabilities: PeerCapabilities
        /// Direct BLE link (1 hop). Multi-hop recipients stay on BLE: AWDL
        /// only reaches direct neighbors, and relays can't proxy the channel.
        let isDirectlyConnected: Bool
        /// The offer rides the Noise session, so one must already exist.
        let hasEstablishedNoiseSession: Bool
    }

    static func shouldOffer(
        _ candidate: SendCandidate,
        enabled: Bool = TransportConfig.wifiBulkEnabled,
        minPayloadBytes: Int = TransportConfig.wifiBulkMinPayloadBytes,
        maxPayloadBytes: Int = FileTransferLimits.maxWifiBulkPayloadBytes
    ) -> Bool {
        enabled
            && candidate.payloadBytes > minPayloadBytes
            && candidate.payloadBytes <= maxPayloadBytes
            && candidate.peerCapabilities.contains(.wifiBulk)
            && candidate.isDirectlyConnected
            && candidate.hasEstablishedNoiseSession
    }

    /// Receiver-side gate. Field lengths were validated at decode; this
    /// enforces the size cap (from the local ceiling, not the sender's word)
    /// and local enablement.
    static func shouldAccept(
        offer: WifiBulkOffer,
        senderIsDirectlyConnected: Bool,
        activeIncomingTransfers: Int,
        enabled: Bool = TransportConfig.wifiBulkEnabled,
        maxPayloadBytes: Int = FileTransferLimits.maxWifiBulkPayloadBytes,
        maxConcurrentIncoming: Int = TransportConfig.wifiBulkMaxConcurrentIncoming
    ) -> Bool {
        enabled
            && senderIsDirectlyConnected
            && activeIncomingTransfers < maxConcurrentIncoming
            && offer.fileSize > 0
            && offer.fileSize <= UInt64(maxPayloadBytes)
    }
}
