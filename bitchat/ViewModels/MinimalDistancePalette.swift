//
// MinimalDistancePalette.swift
// bitchat
//
// Lightweight palette generator that keeps peer colors evenly spaced.
//

import Foundation
import SwiftUI

final class MinimalDistancePalette {
    struct Config {
        let slotCount: Int
        let avoidCenterHue: Double
        let avoidHueDelta: Double
        let saturationLight: Double
        let saturationDark: Double
        let baseBrightnessLight: Double
        let baseBrightnessDark: Double
        let ringBrightnessDeltaLight: Double
        let ringBrightnessDeltaDark: Double
        let preferredBiasWeight: Double
        let goldenStep: Int

        init(
            slotCount: Int,
            avoidCenterHue: Double,
            avoidHueDelta: Double,
            saturationLight: Double,
            saturationDark: Double,
            baseBrightnessLight: Double,
            baseBrightnessDark: Double,
            ringBrightnessDeltaLight: Double,
            ringBrightnessDeltaDark: Double,
            preferredBiasWeight: Double = 0.05,
            goldenStep: Int = 7
        ) {
            self.slotCount = slotCount
            self.avoidCenterHue = avoidCenterHue
            self.avoidHueDelta = avoidHueDelta
            self.saturationLight = saturationLight
            self.saturationDark = saturationDark
            self.baseBrightnessLight = baseBrightnessLight
            self.baseBrightnessDark = baseBrightnessDark
            self.ringBrightnessDeltaLight = ringBrightnessDeltaLight
            self.ringBrightnessDeltaDark = ringBrightnessDeltaDark
            self.preferredBiasWeight = preferredBiasWeight
            self.goldenStep = goldenStep
        }
    }

    private struct Entry {
        let slot: Int
        let ring: Int
        let hue: Double
    }

    private let config: Config
    private var currentSeeds: [String: String] = [:]
    private var entries: [String: Entry] = [:]
    private var previousEntries: [String: Entry] = [:]

    init(config: Config) {
        self.config = config
    }

    @MainActor
    func ensurePalette(for seeds: [String: String]) {
        guard seeds != currentSeeds || entries.count != seeds.count else { return }
        previousEntries = entries
        currentSeeds = seeds
        rebuildEntries()
    }

    @MainActor
    func color(for identifier: String, isDark: Bool) -> Color? {
        guard let entry = entries[identifier] else { return nil }
        let saturation = isDark ? config.saturationDark : config.saturationLight
        let baseBrightness = isDark ? config.baseBrightnessDark : config.baseBrightnessLight
        let ringDelta = isDark ? config.ringBrightnessDeltaDark : config.ringBrightnessDeltaLight
        let brightness = min(1.0, max(0.0, baseBrightness + ringDelta * Double(entry.ring)))
        return Color(hue: entry.hue, saturation: saturation, brightness: brightness)
    }

    @MainActor
    func reset() {
        currentSeeds.removeAll()
        entries.removeAll()
        previousEntries.removeAll()
    }

    @MainActor
    private func rebuildEntries() {
        guard !currentSeeds.isEmpty else {
            entries.removeAll()
            return
        }

        let slotCount = max(8, config.slotCount)
        var slots: [Double] = []
        for idx in 0..<slotCount {
            let hue = Double(idx) / Double(slotCount)
            if abs(hue - config.avoidCenterHue) < config.avoidHueDelta {
                continue
            }
            slots.append(hue)
        }
        if slots.isEmpty {
            for idx in 0..<slotCount {
                slots.append(Double(idx) / Double(slotCount))
            }
        }

        func circularDistance(_ a: Double, _ b: Double) -> Double {
            let diff = abs(a - b)
            return diff > 0.5 ? 1.0 - diff : diff
        }

        let peerIDs = currentSeeds.keys.sorted()
        let preferredIndex: [String: Int] = Dictionary(uniqueKeysWithValues: peerIDs.map { id in
            let seed = currentSeeds[id] ?? id
            let hash = seed.djb2()
            let index = Int(hash % UInt64(slots.count))
            return (id, index)
        })

        var mapping: [String: Entry] = [:]
        var usedSlots = Set<Int>()
        var usedHues: [Double] = []

        let prior = entries.isEmpty ? previousEntries : entries
        for (id, entry) in prior {
            guard currentSeeds.keys.contains(id), entry.slot < slots.count else { continue }
            let hue = slots[entry.slot]
            mapping[id] = Entry(slot: entry.slot, ring: entry.ring, hue: hue)
            usedSlots.insert(entry.slot)
            usedHues.append(hue)
        }

        let unassigned = peerIDs.filter { mapping[$0] == nil }
        for id in unassigned {
            let preferred = preferredIndex[id] ?? 0
            if !usedSlots.contains(preferred), preferred < slots.count {
                let hue = slots[preferred]
                mapping[id] = Entry(slot: preferred, ring: 0, hue: hue)
                usedSlots.insert(preferred)
                usedHues.append(hue)
                continue
            }

            var bestSlot: Int?
            var bestScore = -Double.infinity
            for slot in 0..<slots.count where !usedSlots.contains(slot) {
                let hue = slots[slot]
                let minDistance = usedHues.isEmpty ? 1.0 : usedHues.map { circularDistance(hue, $0) }.min() ?? 1.0
                let bias = 1.0 - (Double((abs(slot - (preferredIndex[id] ?? 0)) % slots.count)) / Double(slots.count))
                let score = minDistance + config.preferredBiasWeight * bias
                if score > bestScore {
                    bestScore = score
                    bestSlot = slot
                }
            }

            if let slot = bestSlot {
                let hue = slots[slot]
                mapping[id] = Entry(slot: slot, ring: 0, hue: hue)
                usedSlots.insert(slot)
                usedHues.append(hue)
            }
        }

        let remaining = peerIDs.filter { mapping[$0] == nil }
        if !remaining.isEmpty {
            for (index, id) in remaining.enumerated() {
                let preferred = preferredIndex[id] ?? 0
                let slot = (preferred + index * config.goldenStep) % slots.count
                let hue = slots[slot]
                mapping[id] = Entry(slot: slot, ring: 1, hue: hue)
            }
        }

        entries = mapping
    }
}

extension MinimalDistancePalette.Config {
    static let mesh = MinimalDistancePalette.Config(
        slotCount: TransportConfig.uiPeerPaletteSlots,
        avoidCenterHue: 30.0 / 360.0,
        avoidHueDelta: TransportConfig.uiColorHueAvoidanceDelta,
        saturationLight: 0.70,
        saturationDark: 0.80,
        baseBrightnessLight: 0.45,
        baseBrightnessDark: 0.75,
        ringBrightnessDeltaLight: TransportConfig.uiPeerPaletteRingBrightnessDeltaLight,
        ringBrightnessDeltaDark: TransportConfig.uiPeerPaletteRingBrightnessDeltaDark
    )

    static let nostr = MinimalDistancePalette.Config(
        slotCount: TransportConfig.uiPeerPaletteSlots,
        avoidCenterHue: 30.0 / 360.0,
        avoidHueDelta: TransportConfig.uiColorHueAvoidanceDelta,
        saturationLight: 0.70,
        saturationDark: 0.80,
        baseBrightnessLight: 0.45,
        baseBrightnessDark: 0.75,
        ringBrightnessDeltaLight: TransportConfig.uiPeerPaletteRingBrightnessDeltaLight,
        ringBrightnessDeltaDark: TransportConfig.uiPeerPaletteRingBrightnessDeltaDark
    )
}
