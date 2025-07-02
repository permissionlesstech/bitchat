import Foundation

// Binary Protocol Format:
// Header (Fixed 13 bytes):
// - Version: 1 byte
// - Type: 1 byte  
// - TTL: 1 byte
// - Timestamp: 8 bytes (UInt64)
// - Flags: 1 byte (bit 0: hasRecipient, bit 1: hasSignature)
// - PayloadLength: 2 bytes (UInt16)
//
// Variable sections:
// - SenderID: 8 bytes (fixed)
// - RecipientID: 8 bytes (if hasRecipient flag set)
// - Payload: Variable length
// - Signature: 64 bytes (if hasSignature flag set)

struct BinaryProtocol {
    static let headerSize = 13
    static let senderIDSize = 8
    static let recipientIDSize = 8
    static let signatureSize = 64
    
    struct Flags {
        static let hasRecipient: UInt8 = 0x01
        static let hasSignature: UInt8 = 0x02
    }
    
    // Encode BitchatPacket to binary format
    static func encode(_ packet: BitchatPacket) -> Data? {
        var data = Data()
        
        // Header
        data.append(packet.version)
        data.append(packet.type)
        data.append(packet.ttl)
        
        // Timestamp (8 bytes, big-endian)
        withUnsafeBytes(of: packet.timestamp.bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
        
        // Flags
        var flags: UInt8 = 0
        if packet.recipientID != nil {
            flags |= Flags.hasRecipient
        }
        if packet.signature != nil {
            flags |= Flags.hasSignature
        }
        data.append(flags)
        
        // Payload length (2 bytes, big-endian)
        let payloadLength = UInt16(packet.payload.count)
        withUnsafeBytes(of: payloadLength.bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
        
        // SenderID (exactly 8 bytes)
        let senderBytes = packet.senderID.prefix(senderIDSize)
        data.append(senderBytes)
        if senderBytes.count < senderIDSize {
            data.append(Data(repeating: 0, count: senderIDSize - senderBytes.count))
        }
        
        // RecipientID (if present)
        if let recipientID = packet.recipientID {
            let recipientBytes = recipientID.prefix(recipientIDSize)
            data.append(recipientBytes)
            if recipientBytes.count < recipientIDSize {
                data.append(Data(repeating: 0, count: recipientIDSize - recipientBytes.count))
            }
        }
        
        // Payload
        data.append(packet.payload)
        
        // Signature (if present)
        if let signature = packet.signature {
            data.append(signature.prefix(signatureSize))
        }
        
        return data
    }
    
    // Decode binary data to BitchatPacket
    static func decode(_ data: Data) -> BitchatPacket? {
        guard data.count >= headerSize + senderIDSize else { return nil }
        
        var offset = 0
        
        // Header
        _ = data[offset]; offset += 1 // version
        let type = data[offset]; offset += 1
        let ttl = data[offset]; offset += 1
        
        // Timestamp
        let timestamp = data[offset..<offset+8].withUnsafeBytes { bytes in
            bytes.load(as: UInt64.self).bigEndian
        }
        offset += 8
        
        // Flags
        let flags = data[offset]; offset += 1
        let hasRecipient = (flags & Flags.hasRecipient) != 0
        let hasSignature = (flags & Flags.hasSignature) != 0
        
        // Payload length
        let payloadLength = data[offset..<offset+2].withUnsafeBytes { bytes in
            bytes.load(as: UInt16.self).bigEndian
        }
        offset += 2
        
        // Calculate expected total size
        var expectedSize = headerSize + senderIDSize + Int(payloadLength)
        if hasRecipient {
            expectedSize += recipientIDSize
        }
        if hasSignature {
            expectedSize += signatureSize
        }
        
        guard data.count >= expectedSize else { return nil }
        
        // SenderID
        let senderID = data[offset..<offset+senderIDSize]
        offset += senderIDSize
        
        // RecipientID
        var recipientID: Data?
        if hasRecipient {
            recipientID = data[offset..<offset+recipientIDSize]
            offset += recipientIDSize
        }
        
        // Payload
        let payload = data[offset..<offset+Int(payloadLength)]
        offset += Int(payloadLength)
        
        // Signature
        var signature: Data?
        if hasSignature {
            signature = data[offset..<offset+signatureSize]
        }
        
        return BitchatPacket(
            type: type,
            senderID: senderID,
            recipientID: recipientID,
            timestamp: timestamp,
            payload: payload,
            signature: signature,
            ttl: ttl
        )
    }
}

// Binary encoding for BitchatMessage
extension BitchatMessage {
    func toBinaryPayload() -> Data? {
        var data = Data()
        
        // Message format:
        // - Flags: 1 byte (bit 0: isRelay, bit 1: isPrivate, bit 2: hasOriginalSender, bit 3: hasRecipientNickname, bit 4: hasSenderPeerID)
        // - Timestamp: 8 bytes (seconds since epoch)
        // - ID length: 1 byte
        // - ID: variable
        // - Sender length: 1 byte
        // - Sender: variable
        // - Content length: 2 bytes
        // - Content: variable
        // Optional fields based on flags:
        // - Original sender length + data
        // - Recipient nickname length + data
        // - Sender peer ID length + data
        
        var flags: UInt8 = 0
        if isRelay { flags |= 0x01 }
        if isPrivate { flags |= 0x02 }
        if originalSender != nil { flags |= 0x04 }
        if recipientNickname != nil { flags |= 0x08 }
        if senderPeerID != nil { flags |= 0x10 }
        
        data.append(flags)
        
        // Timestamp
        let timestampSeconds = UInt64(timestamp.timeIntervalSince1970)
        withUnsafeBytes(of: timestampSeconds.bigEndian) { bytes in
            data.append(contentsOf: bytes)
        }
        
        // ID
        if let idData = id.data(using: .utf8) {
            data.append(UInt8(min(idData.count, 255)))
            data.append(idData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Sender
        if let senderData = sender.data(using: .utf8) {
            data.append(UInt8(min(senderData.count, 255)))
            data.append(senderData.prefix(255))
        } else {
            data.append(0)
        }
        
        // Content
        if let contentData = content.data(using: .utf8) {
            let length = UInt16(min(contentData.count, 65535))
            withUnsafeBytes(of: length.bigEndian) { bytes in
                data.append(contentsOf: bytes)
            }
            data.append(contentData.prefix(Int(length)))
        } else {
            data.append(contentsOf: [0, 0])
        }
        
        // Optional fields
        if let originalSender = originalSender, let origData = originalSender.data(using: .utf8) {
            data.append(UInt8(min(origData.count, 255)))
            data.append(origData.prefix(255))
        }
        
        if let recipientNickname = recipientNickname, let recipData = recipientNickname.data(using: .utf8) {
            data.append(UInt8(min(recipData.count, 255)))
            data.append(recipData.prefix(255))
        }
        
        if let senderPeerID = senderPeerID, let peerData = senderPeerID.data(using: .utf8) {
            data.append(UInt8(min(peerData.count, 255)))
            data.append(peerData.prefix(255))
        }
        
        return data
    }
    
    static func fromBinaryPayload(_ data: Data) -> BitchatMessage? {
        guard data.count >= 13 else { return nil } // Minimum size
        
        var offset = 0
        
        // Flags
        let flags = data[offset]; offset += 1
        let isRelay = (flags & 0x01) != 0
        let isPrivate = (flags & 0x02) != 0
        let hasOriginalSender = (flags & 0x04) != 0
        let hasRecipientNickname = (flags & 0x08) != 0
        let hasSenderPeerID = (flags & 0x10) != 0
        
        // Timestamp
        let timestampSeconds = data[offset..<offset+8].withUnsafeBytes { bytes in
            bytes.load(as: UInt64.self).bigEndian
        }
        offset += 8
        let timestamp = Date(timeIntervalSince1970: TimeInterval(timestampSeconds))
        
        // ID
        let idLength = Int(data[offset]); offset += 1
        guard offset + idLength <= data.count else { return nil }
        _ = String(data: data[offset..<offset+idLength], encoding: .utf8) ?? UUID().uuidString
        offset += idLength
        
        // Sender
        guard offset < data.count else { return nil }
        let senderLength = Int(data[offset]); offset += 1
        guard offset + senderLength <= data.count else { return nil }
        let sender = String(data: data[offset..<offset+senderLength], encoding: .utf8) ?? "unknown"
        offset += senderLength
        
        // Content
        guard offset + 2 <= data.count else { return nil }
        let contentLength = data[offset..<offset+2].withUnsafeBytes { bytes in
            Int(bytes.load(as: UInt16.self).bigEndian)
        }
        offset += 2
        guard offset + contentLength <= data.count else { return nil }
        let content = String(data: data[offset..<offset+contentLength], encoding: .utf8) ?? ""
        offset += contentLength
        
        // Optional fields
        var originalSender: String?
        if hasOriginalSender && offset < data.count {
            let length = Int(data[offset]); offset += 1
            if offset + length <= data.count {
                originalSender = String(data: data[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        var recipientNickname: String?
        if hasRecipientNickname && offset < data.count {
            let length = Int(data[offset]); offset += 1
            if offset + length <= data.count {
                recipientNickname = String(data: data[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        var senderPeerID: String?
        if hasSenderPeerID && offset < data.count {
            let length = Int(data[offset]); offset += 1
            if offset + length <= data.count {
                senderPeerID = String(data: data[offset..<offset+length], encoding: .utf8)
                offset += length
            }
        }
        
        return BitchatMessage(
            sender: sender,
            content: content,
            timestamp: timestamp,
            isRelay: isRelay,
            originalSender: originalSender,
            isPrivate: isPrivate,
            recipientNickname: recipientNickname,
            senderPeerID: senderPeerID
        )
    }
}