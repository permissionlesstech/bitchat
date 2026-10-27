//
// H264NalUnitsTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
@testable import bitchat

struct H264NalUnitsTests {
    private let sps = Data([0x67, 0x42, 0x00, 0x1E])
    private let pps = Data([0x68, 0xCE, 0x38, 0x80])
    private let idr = Data([0x65, 0x11, 0x22, 0x33])
    private let filler = Data([0x0C, 0xFF, 0xFF, 0x80])

    @Test func splitsMixedStartCodes() {
        let data = Data([0, 0, 0, 1]) + sps + Data([0, 0, 1]) + pps + Data([0, 0, 0, 1]) + idr
        let nals = H264NalUnits.split(data)
        #expect(nals == [sps, pps, idr])
        #expect(H264NalUnits.type(nals[2]) == H264NalUnits.typeIDR)
        #expect(H264NalUnits.type(Data()) == -1)
        #expect(H264NalUnits.containsType(data, H264NalUnits.typeIDR))
        #expect(!H264NalUnits.containsType(data, H264NalUnits.typeFiller))
    }

    @Test func splitsSlicesWithNonZeroStartIndex() {
        let padded = Data([0xAA]) + H264NalUnits.join([sps, idr])
        #expect(H264NalUnits.split(padded[1...]) == [sps, idr])
    }

    @Test func liftsParameterSetsAndStripsThemForMuxing() throws {
        let keyframe = H264NalUnits.join([Data([0x09, 0xF0]), sps, pps, idr])
        let sets = try #require(H264NalUnits.parameterSets(keyframe))
        // Raw NAL payloads, as CMVideoFormatDescriptionCreateFromH264ParameterSets expects.
        #expect(sets.sps == sps)
        #expect(sets.pps == pps)
        #expect(H264NalUnits.withoutParameterSets(keyframe) == H264NalUnits.join([idr]))
        #expect(H264NalUnits.parameterSets(H264NalUnits.join([idr])) == nil)
        #expect(H264NalUnits.parameterSets(H264NalUnits.join([sps, idr])) == nil)
    }

    @Test func dropsFillerOnly() {
        let unit = H264NalUnits.join([idr, filler])
        #expect(H264NalUnits.withoutFiller(unit) == H264NalUnits.join([idr]))
        let clean = H264NalUnits.join([idr])
        #expect(H264NalUnits.withoutFiller(clean) == clean)
    }
}
