//
// NotificationStreamAssembler.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation

struct NotificationStreamAssembler {
    private var buffer = Data()

    mutating func append(_ chunk: Data) -> (frames: [Data], droppedPrefixes: [UInt8], reset: Bool) {
        guard !chunk.isEmpty else { return ([], [], false) }

        buffer.append(chunk)

        var frames: [Data] = []
        var dropped: [UInt8] = []
        var reset = false
        let maxFrameLength = TransportConfig.blePendingWriteBufferCapBytes

        let minHeaderBytes = 14 // version + type + ttl + timestamp(8) + flags + length(2)
        let minFramePrefix = minHeaderBytes + BinaryProtocol.senderIDSize

        while buffer.count >= minFramePrefix {
            guard let first = buffer.first else { break }
            if first != 1 {
                dropped.append(buffer.removeFirst())
                continue
            }

            guard buffer.count >= minHeaderBytes else { break }

            let headerBytes = Array(buffer.prefix(minFramePrefix))
            guard headerBytes.count == minFramePrefix else { break }

            let flags = headerBytes[11]
            let hasRecipient = (flags & BinaryProtocol.Flags.hasRecipient) != 0
            let hasSignature = (flags & BinaryProtocol.Flags.hasSignature) != 0
            let payloadLen = (Int(headerBytes[12]) << 8) | Int(headerBytes[13])

            var frameLength = minFramePrefix + payloadLen
            if hasRecipient { frameLength += BinaryProtocol.recipientIDSize }
            if hasSignature { frameLength += BinaryProtocol.signatureSize }

            guard frameLength > 0, frameLength <= maxFrameLength else {
                buffer.removeAll()
                reset = true
                break
            }

            if buffer.count < frameLength {
                // Check if a new frame start exists within the incomplete buffer; if so, drop leading partial bytes.
                if let nextStart = buffer.dropFirst().firstIndex(of: 1) {
                    let dropCount = buffer.distance(from: buffer.startIndex, to: nextStart)
                    if dropCount > 0 {
                        buffer.removeFirst(dropCount)
                        dropped.append(1) // treat as dropped partial start
                    }
                }
                break
            }

            let frame = Data(buffer.prefix(frameLength))
            frames.append(frame)
            buffer.removeFirst(frameLength)
        }

        if !buffer.isEmpty, buffer.allSatisfy({ $0 == 0 }) {
            buffer.removeAll(keepingCapacity: false)
        }

        return (frames, dropped, reset)
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
