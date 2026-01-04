//
// NotificationStreamAssembler.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import BitLogger
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

        while buffer.count >= minimumFramePrefix {
            guard let version = buffer.first else { break }
            guard version == 1 || version == 2 else {
                dropped.append(buffer.removeFirst())
                pendingFrameStartedAt = nil
                pendingFrameExpectedLength = 0
                continue
            }

            guard let headerSize = BinaryProtocol.headerSize(for: version) else {
                dropped.append(buffer.removeFirst())
                pendingFrameStartedAt = nil
                pendingFrameExpectedLength = 0
                continue
            }
            let framePrefix = headerSize + BinaryProtocol.senderIDSize
            guard buffer.count >= framePrefix else { break }

            let flagsIndex = buffer.startIndex + BinaryProtocol.Offsets.flags
            guard flagsIndex < buffer.endIndex else { break }
            let flags = buffer[flagsIndex]
            let hasRecipient = (flags & BinaryProtocol.Flags.hasRecipient) != 0
            let hasSignature = (flags & BinaryProtocol.Flags.hasSignature) != 0
            let isCompressed = (flags & BinaryProtocol.Flags.isCompressed) != 0

            let lengthOffset = 12
            let payloadLength: Int
            if version == 2 {
                let lengthIndex = buffer.startIndex + lengthOffset
                payloadLength =
                    (Int(buffer[lengthIndex]) << 24) |
                    (Int(buffer[lengthIndex + 1]) << 16) |
                    (Int(buffer[lengthIndex + 2]) << 8) |
                    Int(buffer[lengthIndex + 3])
            } else {
                let lengthIndex = buffer.startIndex + lengthOffset
                payloadLength = (Int(buffer[lengthIndex]) << 8) | Int(buffer[lengthIndex + 1])
            }

            var frameLength = framePrefix + payloadLength
            if hasRecipient { frameLength += BinaryProtocol.recipientIDSize }
            if hasSignature { frameLength += BinaryProtocol.signatureSize }
            if isCompressed {
                let rawLengthFieldBytes = (version == 2) ? 4 : 2
                if payloadLength < rawLengthFieldBytes {
                    SecureLogger.error("❌ Invalid compressed payload length (\(payloadLength))", category: .session)
                    resetState()
                    didReset = true
                    break
                }
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

            let frame = Data(buffer.prefix(frameLength))
            frames.append(frame)
            buffer.removeFirst(frameLength)
        }

        if !buffer.isEmpty, buffer.allSatisfy({ $0 == 0 }) {
            resetState()
        }

        return (frames, dropped, didReset)
    }
}
