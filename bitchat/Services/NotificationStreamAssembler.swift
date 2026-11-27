//
// NotificationStreamAssembler.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
import BitFoundation
import Foundation

struct NotificationStreamAssembler {
    private var buffer = Data()
    private var pendingFrameStartedAt: DispatchTime?
    private var pendingFrameExpectedLength: Int = 0

    private mutating func resetState() {
        buffer.removeAll(keepingCapacity: false)
        pendingFrameStartedAt = nil
        pendingFrameExpectedLength = 0
    }

    private mutating func discardLeadingPaddingIfPresent() -> Bool {
        guard let first = buffer.first else { return false }
        guard first != 1 && first != 2 else { return false }
        let paddingLength = Int(first)
        guard paddingLength > 0, paddingLength <= buffer.count else { return false }
        guard buffer.prefix(paddingLength).allSatisfy({ $0 == first }) else { return false }

        buffer.removeFirst(paddingLength)
        pendingFrameStartedAt = nil
        pendingFrameExpectedLength = 0
        return true
    }

    mutating func append(_ chunk: Data) -> (frames: [Data], droppedPrefixes: [UInt8], reset: Bool) {
        guard !chunk.isEmpty else { return ([], [], false) }

        buffer.append(chunk)

        var frames: [Data] = []
        var dropped: [UInt8] = []
        var didReset = false
        let now = DispatchTime.now()
        let maxFrameLength = TransportConfig.bleNotificationAssemblerHardCapBytes
        let minimumFramePrefix = BinaryProtocol.v1HeaderSize + BinaryProtocol.senderIDSize

        if buffer.count > TransportConfig.bleNotificationAssemblerHardCapBytes {
            SecureLogger.error("❌ Notification assembler overflow (\(buffer.count) bytes); dropping partial frame", category: .session)
            resetState()
            return ([], [], true)
        }

        loop: while buffer.count >= minimumFramePrefix {
            guard let version = buffer.first else { break }
            guard version == 1 || version == 2 else {
                if discardLeadingPaddingIfPresent() {
                    continue
                }
                dropped.append(buffer.removeFirst())
                pendingFrameStartedAt = nil
                pendingFrameExpectedLength = 0
                continue
            }

            let frameLength: Int
            switch BinaryProtocol.expectedFrameLength(for: buffer) {
            case .incomplete:
                break loop
            case .invalid:
                SecureLogger.error("❌ Invalid notification frame header; resetting stream", category: .session)
                resetState()
                didReset = true
                break loop
            case .length(let expected):
                frameLength = expected
            }

            guard frameLength > 0, frameLength <= maxFrameLength else {
                SecureLogger.error("❌ Notification frame length \(frameLength) invalid (cap=\(maxFrameLength)); resetting stream", category: .session)
                resetState()
                didReset = true
                break
            }

            if buffer.count < frameLength {
                let remaining = frameLength - buffer.count
                if pendingFrameStartedAt == nil || frameLength != pendingFrameExpectedLength {
                    pendingFrameStartedAt = now
                    pendingFrameExpectedLength = frameLength
                } else if let started = pendingFrameStartedAt {
                    let elapsed = now.uptimeNanoseconds - started.uptimeNanoseconds
                    let threshold = UInt64(TransportConfig.bleAssemblerStallResetMs) * 1_000_000
                    if elapsed >= threshold {
                        SecureLogger.debug("📉 Resetting notification assembler after waiting \(remaining)B for \(TransportConfig.bleAssemblerStallResetMs)ms", category: .session)
                        resetState()
                        didReset = true
                    } else {
                        SecureLogger.debug("⌛ Waiting for remaining \(remaining)B to complete BLE frame", category: .session)
                    }
                }
                break
            }

            pendingFrameStartedAt = nil
            pendingFrameExpectedLength = 0

            if frameLength == buffer.count {
                frames.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                let frame = Data(buffer.prefix(frameLength))
                frames.append(frame)
                buffer.removeFirst(frameLength)
                _ = discardLeadingPaddingIfPresent()
            }
        }

        if discardLeadingPaddingIfPresent() {
            return (frames, dropped, didReset)
        }

        if !buffer.isEmpty, buffer.allSatisfy({ $0 == 0 }) {
            resetState()
        }

        return (frames, dropped, didReset)
    }
}
