//
// PrivateChatSwipeToLeavePolicyTests.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import CoreGraphics
import Foundation
@testable import bitchat

/// A stand-in for the playback slot holder. The coordinator only needs identity
/// and the ability to be told to yield.
private final class StubPlayback: ExclusivePlayback {
    private(set) var pauseCount = 0
    func pauseForExclusivity() { pauseCount += 1 }
}

@Suite("PrivateChatSwipeToLeavePolicy")
struct PrivateChatSwipeToLeavePolicyTests {

    // MARK: - Thresholds preserved

    @Test("a decisive rightward drag leaves when nothing is playing")
    func decisiveDragLeaves() {
        #expect(PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: 120, height: 10),
            isVoiceNotePlaying: false
        ))
    }

    @Test("a drag that does not clear the horizontal threshold does not leave")
    func shortDragStays() {
        #expect(!PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: 80, height: 0),
            isVoiceNotePlaying: false
        ))
    }

    @Test("a leftward drag never leaves")
    func leftwardDragStays() {
        #expect(!PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: -120, height: 0),
            isVoiceNotePlaying: false
        ))
    }

    @Test("a steep drag reads as a scroll, not a leave", arguments: [60.0, 61.0, -60.0, -90.0])
    func steepDragStays(vertical: Double) {
        #expect(!PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: 200, height: vertical),
            isVoiceNotePlaying: false
        ))
    }

    @Test("vertical travel is judged on magnitude, so a shallow upward drag still leaves")
    func shallowUpwardDragLeaves() {
        #expect(PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: 200, height: -59),
            isVoiceNotePlaying: false
        ))
    }

    // MARK: - The regression this policy exists for

    @Test("a drag that would otherwise leave is suppressed while a voice note plays")
    func playbackSuppressesLeave() {
        // The reported bug: scrubbing a playing waveform drifts right, the
        // high-priority ancestor claims the drag, and the conversation ends.
        #expect(!PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: 200, height: 5),
            isVoiceNotePlaying: true
        ))
    }

    @Test("suppression lifts once playback stops")
    func leaveResumesAfterPlayback() {
        let translation = CGSize(width: 200, height: 5)
        #expect(!PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: translation, isVoiceNotePlaying: true))
        #expect(PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: translation, isVoiceNotePlaying: false))
    }

    @Test("playback does not rescue a drag that never qualified")
    func playbackDoesNotInventALeave() {
        #expect(!PrivateChatSwipeToLeavePolicy.shouldLeave(
            translation: CGSize(width: 10, height: 200),
            isVoiceNotePlaying: true
        ))
    }
}

@Suite("VoiceNotePlaybackCoordinator.hasActivePlayback")
struct VoiceNotePlaybackCoordinatorActivityTests {

    @Test("an idle coordinator reports no active playback")
    func idleCoordinator() {
        #expect(!VoiceNotePlaybackCoordinator().hasActivePlayback)
    }

    @Test("activating a controller marks playback active")
    func activationMarksActive() {
        let coordinator = VoiceNotePlaybackCoordinator()
        let playback = StubPlayback()
        coordinator.activate(playback)
        #expect(coordinator.hasActivePlayback)
    }

    @Test("deactivating the active controller clears it")
    func deactivationClears() {
        let coordinator = VoiceNotePlaybackCoordinator()
        let playback = StubPlayback()
        coordinator.activate(playback)
        coordinator.deactivate(playback)
        #expect(!coordinator.hasActivePlayback)
    }

    @Test("a reservation alone does not count as playing")
    func reservationIsNotPlayback() {
        // `reserve` records intent before an async starter has audio ready;
        // treating that as playing would suppress the leave gesture on a note
        // that never becomes audible.
        let coordinator = VoiceNotePlaybackCoordinator()
        _ = coordinator.reserve(StubPlayback())
        #expect(!coordinator.hasActivePlayback)
    }

    @Test("deactivating a controller that does not hold the slot leaves it active")
    func foreignDeactivateIsIgnored() {
        let coordinator = VoiceNotePlaybackCoordinator()
        let holder = StubPlayback()
        coordinator.activate(holder)
        coordinator.deactivate(StubPlayback())
        #expect(coordinator.hasActivePlayback)
    }

    @Test("a controller that pauses releases the slot")
    func pauseReleasesSlot() throws {
        // The slot means audible playback. A paused note holds nothing, and
        // leaving it in place kept the leave gesture suppressed for the rest
        // of the row's life.
        let coordinator = VoiceNotePlaybackCoordinator()
        let url = try Self.makeSilentVoiceNote()
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = VoiceNotePlaybackController(url: url, exclusivity: coordinator)

        controller.play()
        #expect(coordinator.hasActivePlayback)

        controller.pause()
        #expect(!coordinator.hasActivePlayback)
    }

    /// A one-frame WAV: enough for AVAudioPlayer to prepare and start.
    private static func makeSilentVoiceNote() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swipe-policy-\(UUID().uuidString).wav")
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let frames: UInt32 = 8_000            // one second at 8 kHz, 16-bit mono
        let dataBytes = frames * 2
        append("RIFF"); append(36 + dataBytes); append("WAVE")
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        append("data"); append(dataBytes)
        data.append(Data(repeating: 0, count: Int(dataBytes)))
        try data.write(to: url)
        return url
    }

    @Test("taking over the slot pauses the previous holder and stays active")
    func takeoverKeepsPlaybackActive() {
        let coordinator = VoiceNotePlaybackCoordinator()
        let first = StubPlayback()
        let second = StubPlayback()
        coordinator.activate(first)
        coordinator.activate(second)
        #expect(first.pauseCount == 1)
        #expect(coordinator.hasActivePlayback)
    }
}
