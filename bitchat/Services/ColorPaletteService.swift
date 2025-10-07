//
// ColorPaletteService.swift
// bitchat
//
// Manages consistent color assignment for peers using minimal-distance algorithm
// This is free and unencumbered software released into the public domain.
//

import Foundation
import SwiftUI

/// Service that assigns consistent, visually distinct colors to peers
/// Uses a minimal-distance hue assignment algorithm to maximize color separation
final class ColorPaletteService {

    // MARK: - Palette State

    private var peerPaletteLight: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var peerPaletteDark: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var peerPaletteSeeds: [String: String] = [:] // peerID -> seed used

    private var nostrPaletteLight: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var nostrPaletteDark: [String: (slot: Int, ring: Int, hue: Double)] = [:]
    private var nostrPaletteSeeds: [String: String] = [:] // pubkey -> seed used

    // MARK: - Configuration

    private let slotCount: Int
    private let avoidCenter: Double // Hue to avoid (typically orange for self)
    private let avoidDelta: Double
    private let saturationDark: Double
    private let saturationLight: Double
    private let baseBrightnessDark: Double
    private let baseBrightnessLight: Double
    private let ringDeltaDark: Double
    private let ringDeltaLight: Double

    // MARK: - Initialization

    init(
        slotCount: Int = max(8, TransportConfig.uiPeerPaletteSlots),
        avoidCenter: Double = 30.0 / 360.0, // Orange hue
        avoidDelta: Double = TransportConfig.uiColorHueAvoidanceDelta,
        saturationDark: Double = 0.80,
        saturationLight: Double = 0.70,
        baseBrightnessDark: Double = 0.75,
        baseBrightnessLight: Double = 0.45,
        ringDeltaDark: Double = TransportConfig.uiPeerPaletteRingBrightnessDeltaDark,
        ringDeltaLight: Double = TransportConfig.uiPeerPaletteRingBrightnessDeltaLight
    ) {
        self.slotCount = slotCount
        self.avoidCenter = avoidCenter
        self.avoidDelta = avoidDelta
        self.saturationDark = saturationDark
        self.saturationLight = saturationLight
        self.baseBrightnessDark = baseBrightnessDark
        self.baseBrightnessLight = baseBrightnessLight
        self.ringDeltaDark = ringDeltaDark
        self.ringDeltaLight = ringDeltaLight
    }

    // MARK: - Public API

    /// Get color for a mesh peer
    func colorForMeshPeer(
        peerID: String,
        isDark: Bool,
        myPeerID: String,
        allPeers: [BitchatPeer],
        getNoiseKeyForShortID: (String) -> String?
    ) -> Color {
        // Ensure palette is up to date
        rebuildPeerPaletteIfNeeded(
            myPeerID: myPeerID,
            allPeers: allPeers,
            getNoiseKeyForShortID: getNoiseKeyForShortID
        )

        let entry = (isDark ? peerPaletteDark[peerID] : peerPaletteLight[peerID])
        let orange = Color.orange
        if peerID == myPeerID { return orange }

        let saturation: Double = isDark ? saturationDark : saturationLight
        let baseBrightness: Double = isDark ? baseBrightnessDark : baseBrightnessLight
        let ringDelta = isDark ? ringDeltaDark : ringDeltaLight

        if let e = entry {
            let brightness = min(1.0, max(0.0, baseBrightness + ringDelta * Double(e.ring)))
            return Color(hue: e.hue, saturation: saturation, brightness: brightness)
        }

        // Fallback to seed color if not in palette
        let seed = meshSeed(for: peerID, getNoiseKeyForShortID: getNoiseKeyForShortID)
        return Color(peerSeed: seed, isDark: isDark)
    }

    /// Get color for a Nostr participant
    func colorForNostrPubkey(
        pubkeyHexLowercased: String,
        isDark: Bool,
        myNostrPubkey: String?,
        geohashPeople: [(id: String, seed: String)]
    ) -> Color {
        rebuildNostrPaletteIfNeeded(
            myNostrPubkey: myNostrPubkey,
            geohashPeople: geohashPeople
        )

        let entry = (isDark ? nostrPaletteDark[pubkeyHexLowercased] : nostrPaletteLight[pubkeyHexLowercased])
        if let me = myNostrPubkey, pubkeyHexLowercased == me { return .orange }

        let saturation: Double = isDark ? saturationDark : saturationLight
        let baseBrightness: Double = isDark ? baseBrightnessDark : baseBrightnessLight
        let ringDelta = isDark ? ringDeltaDark : ringDeltaLight

        if let e = entry {
            let brightness = min(1.0, max(0.0, baseBrightness + ringDelta * Double(e.ring)))
            return Color(hue: e.hue, saturation: saturation, brightness: brightness)
        }

        // Fallback to seed color
        return Color(peerSeed: "nostr:" + pubkeyHexLowercased, isDark: isDark)
    }

    /// Get color for a message sender (auto-detects type)
    func peerColor(
        for message: BitchatMessage,
        isDark: Bool,
        myPeerID: String,
        myNostrPubkey: String?,
        nostrKeyMapping: [String: String],
        allPeers: [BitchatPeer],
        geohashPeople: [(id: String, seed: String)],
        getNoiseKeyForShortID: (String) -> String?
    ) -> Color {
        if let spid = message.senderPeerID?.id {
            if spid.hasPrefix("nostr:") || spid.hasPrefix("nostr_") {
                let bare: String = {
                    if spid.hasPrefix("nostr:") { return String(spid.dropFirst(6)) }
                    if spid.hasPrefix("nostr_") { return String(spid.dropFirst(6)) }
                    return spid
                }()
                let full = nostrKeyMapping[spid]?.lowercased() ?? bare.lowercased()
                return colorForNostrPubkey(
                    pubkeyHexLowercased: full,
                    isDark: isDark,
                    myNostrPubkey: myNostrPubkey,
                    geohashPeople: geohashPeople
                )
            } else if spid.count == 16 {
                return colorForMeshPeer(
                    peerID: spid,
                    isDark: isDark,
                    myPeerID: myPeerID,
                    allPeers: allPeers,
                    getNoiseKeyForShortID: getNoiseKeyForShortID
                )
            } else {
                return colorForMeshPeer(
                    peerID: spid.lowercased(),
                    isDark: isDark,
                    myPeerID: myPeerID,
                    allPeers: allPeers,
                    getNoiseKeyForShortID: getNoiseKeyForShortID
                )
            }
        }
        // Fallback when we only have a display name
        return Color(peerSeed: message.sender.lowercased(), isDark: isDark)
    }

    /// Reset all palette state (useful for testing)
    func reset() {
        peerPaletteLight.removeAll()
        peerPaletteDark.removeAll()
        peerPaletteSeeds.removeAll()
        nostrPaletteLight.removeAll()
        nostrPaletteDark.removeAll()
        nostrPaletteSeeds.removeAll()
    }

    // MARK: - Private Helpers

    private func meshSeed(for peerID: String, getNoiseKeyForShortID: (String) -> String?) -> String {
        if let full = getNoiseKeyForShortID(peerID)?.lowercased() {
            return "noise:" + full
        }
        return peerID.lowercased()
    }

    private func rebuildPeerPaletteIfNeeded(
        myPeerID: String,
        allPeers: [BitchatPeer],
        getNoiseKeyForShortID: (String) -> String?
    ) {
        // Build current peer->seed map (excluding self)
        var currentSeeds: [String: String] = [:]
        for p in allPeers where p.peerID.id != myPeerID {
            currentSeeds[p.peerID.id] = meshSeed(for: p.peerID.id, getNoiseKeyForShortID: getNoiseKeyForShortID)
        }

        // If seeds unchanged and palette exists for both themes, skip
        if currentSeeds == peerPaletteSeeds,
           peerPaletteLight.keys.count == currentSeeds.count,
           peerPaletteDark.keys.count == currentSeeds.count {
            return
        }
        peerPaletteSeeds = currentSeeds

        // Generate palette
        let mapping = assignColorsMinimalDistance(seeds: currentSeeds, previousMapping: peerPaletteLight)
        peerPaletteLight = mapping
        peerPaletteDark = mapping
    }

    private func rebuildNostrPaletteIfNeeded(
        myNostrPubkey: String?,
        geohashPeople: [(id: String, seed: String)]
    ) {
        // Build seeds map from currently visible geohash people (excluding self)
        var currentSeeds: [String: String] = [:]
        for p in geohashPeople where p.id != myNostrPubkey {
            currentSeeds[p.id] = p.seed
        }

        if currentSeeds == nostrPaletteSeeds,
           nostrPaletteLight.keys.count == currentSeeds.count,
           nostrPaletteDark.keys.count == currentSeeds.count {
            return
        }
        nostrPaletteSeeds = currentSeeds

        let mapping = assignColorsMinimalDistance(seeds: currentSeeds, previousMapping: nostrPaletteLight)
        nostrPaletteLight = mapping
        nostrPaletteDark = mapping
    }

    // MARK: - Minimal-Distance Color Assignment Algorithm

    private func assignColorsMinimalDistance(
        seeds: [String: String],
        previousMapping: [String: (slot: Int, ring: Int, hue: Double)]
    ) -> [String: (slot: Int, ring: Int, hue: Double)] {
        // Generate evenly spaced hue slots avoiding self-orange range
        var slots: [Double] = []
        for i in 0..<slotCount {
            let hue = Double(i) / Double(slotCount)
            if abs(hue - avoidCenter) < avoidDelta { continue }
            slots.append(hue)
        }
        if slots.isEmpty {
            // Safety: if avoidance consumed all (shouldn't happen), fall back to full slots
            for i in 0..<slotCount { slots.append(Double(i) / Double(slotCount)) }
        }

        // Helper to compute circular distance
        func circDist(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b)
            return d > 0.5 ? 1.0 - d : d
        }

        // Assign slots to peers to maximize minimal distance, deterministically
        let peers = seeds.keys.sorted() // stable order

        // Preferred slot index by seed (wrapping to available slots)
        let prefIndex: [String: Int] = Dictionary(uniqueKeysWithValues: peers.map { id in
            let h = (seeds[id] ?? id).djb2()
            let idx = Int(h % UInt64(slots.count))
            return (id, idx)
        })

        var mapping: [String: (slot: Int, ring: Int, hue: Double)] = [:]
        var usedSlots = Set<Int>()
        var usedHues: [Double] = []

        // Keep previous assignments if still valid to minimize churn
        for (id, entry) in previousMapping {
            if seeds.keys.contains(id), entry.slot < slots.count { // slot index still valid
                mapping[id] = (entry.slot, entry.ring, slots[entry.slot])
                usedSlots.insert(entry.slot)
                usedHues.append(slots[entry.slot])
            }
        }

        // First ring assignment using free slots
        let unassigned = peers.filter { mapping[$0] == nil }
        for id in unassigned {
            // If a preferred slot free, take it
            let preferred = prefIndex[id] ?? 0
            if !usedSlots.contains(preferred) && preferred < slots.count {
                mapping[id] = (preferred, 0, slots[preferred])
                usedSlots.insert(preferred)
                usedHues.append(slots[preferred])
                continue
            }
            // Choose free slot maximizing minimal distance to used hues
            var bestSlot: Int? = nil
            var bestScore: Double = -1
            for sIdx in 0..<slots.count where !usedSlots.contains(sIdx) {
                let hue = slots[sIdx]
                let minDist = usedHues.isEmpty ? 1.0 : usedHues.map { circDist(hue, $0) }.min() ?? 1.0
                // Bias toward preferred index for stability
                let bias = 1.0 - (Double((abs(sIdx - (prefIndex[id] ?? 0)) % slots.count)) / Double(slots.count))
                let score = minDist + 0.05 * bias
                if score > bestScore { bestScore = score; bestSlot = sIdx }
            }
            if let s = bestSlot {
                mapping[id] = (s, 0, slots[s])
                usedSlots.insert(s)
                usedHues.append(slots[s])
            }
        }

        // Overflow peers: assign additional rings by reusing slots with stable preference
        let stillUnassigned = peers.filter { mapping[$0] == nil }
        if !stillUnassigned.isEmpty {
            for (idx, id) in stillUnassigned.enumerated() {
                let preferred = prefIndex[id] ?? 0
                // Spread over slots by rotating from preferred with a golden-step
                let goldenStep = 7 // small prime step for dispersion
                let s = (preferred + idx * goldenStep) % slots.count
                mapping[id] = (s, 1, slots[s])
            }
        }

        return mapping
    }
}
