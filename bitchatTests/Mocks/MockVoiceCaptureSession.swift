//
// MockVoiceCaptureSession.swift
// bitchatTests
//
// A `VoiceCaptureSession` whose permission answer, start outcome and
// finalize are scripted by the test, so a hold can be walked through every
// phase deterministically.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
@testable import bitchat

@MainActor
final class MockVoiceCaptureSession: VoiceCaptureSession {
    let isLive: Bool
    var grantsPermission = true
    private let startError: Error?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var panicCancelCount = 0
    private(set) var finishStarted = false
    private var finishContinuation: CheckedContinuation<URL?, Never>?

    init(isLive: Bool = false, startError: Error? = nil) {
        self.isLive = isLive
        self.startError = startError
    }

    func requestPermission() async -> Bool { grantsPermission }

    func start() async throws {
        startCount += 1
        if let startError { throw startError }
    }

    /// Stays pending until `resolveFinish(with:)`, like a classic note in
    /// its finalize padding.
    func finish() async -> URL? {
        finishStarted = true
        return await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel() async {
        cancelCount += 1
    }

    func panicCancelSynchronously() {
        panicCancelCount += 1
    }

    func resolveFinish(with url: URL?) {
        let continuation = finishContinuation
        finishContinuation = nil
        continuation?.resume(returning: url)
    }
}
