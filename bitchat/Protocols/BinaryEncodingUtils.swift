//
// BinaryEncodingUtils.swift
// bitchat
//
// Binary encoding utilities for efficient protocol messages
//

import Foundation

// MARK: - Hex Encoding/Decoding

extension Data {
    func hexEncodedString() -> String {
        if self.isEmpty {
            return ""
        }
        return self.map { String(format: "%02x", $0) }.joined()
    }
    
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(String(hexString[index..<nextIndex]), radix: 16) else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }
        
        self = data
    }
}

// MARK: - Binary Encoding Utilities

extension Data {
    // MARK: Writing
    
    mutating func appendUInt8(_ value: UInt8) {
        self.append(value)
    }
    
    mutating func appendUInt16(_ value: UInt16) {
        self.append(UInt8((value >> 8) & 0xFF))
        self.append(UInt8(value & 0xFF))
    }
    
    mutating func appendUInt32(_ value: UInt32) {
        self.append(UInt8((value >> 24) & 0xFF))
        self.append(UInt8((value >> 16) & 0xFF))
        self.append(UInt8((value >> 8) & 0xFF))
        self.append(UInt8(value & 0xFF))
    }
    
    mutating func appendUInt64(_ value: UInt64) {
        for i in (0..<8).reversed() {
            self.append(UInt8((value >> (i * 8)) & 0xFF))
        }
    }
    
    mutating func appendString(_ string: String, maxLength: Int = 255) {
        guard let data = string.data(using: .utf8) else { return }
        let length = Swift.min(data.count, maxLength)
        
        if maxLength <= 255 {
            self.append(UInt8(length))
        } else {
            self.appendUInt16(UInt16(length))
        }
        
        self.append(data.prefix(length))
    }
    
    mutating func appendData(_ data: Data, maxLength: Int = 65535) {
        let length = Swift.min(data.count, maxLength)
        
        if maxLength <= 255 {
            self.append(UInt8(length))
        } else {
            self.appendUInt16(UInt16(length))
        }
        
        self.append(data.prefix(length))
    }
    
    mutating func appendDate(_ date: Date) {
        let timestamp = UInt64(date.timeIntervalSince1970 * 1000) // milliseconds
        self.appendUInt64(timestamp)
    }
    
    mutating func appendUUID(_ uuid: String) {
        // Convert UUID string to 16 bytes
        var uuidData = Data(count: 16)
        
        let cleanUUID = uuid.replacingOccurrences(of: "-", with: "")
        var index = cleanUUID.startIndex
        
        for i in 0..<16 {
            guard index < cleanUUID.endIndex else { break }
            let nextIndex = cleanUUID.index(index, offsetBy: 2)
            if let byte = UInt8(String(cleanUUID[index..<nextIndex]), radix: 16) {
                uuidData[i] = byte
            }
            index = nextIndex
        }
        
        self.append(uuidData)
    }
    
    // MARK: Reading
    
    func readUInt8(at offset: inout Int) -> UInt8? {
        guard offset >= 0 && offset < self.count else { return nil }
        let value = self[offset]
        offset += 1
        return value
    }
    
    func readUInt16(at offset: inout Int) -> UInt16? {
        guard offset + 2 <= self.count else { return nil }
        let value = UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
        offset += 2
        return value
    }
    
    func readUInt32(at offset: inout Int) -> UInt32? {
        guard offset + 4 <= self.count else { return nil }
        let value = UInt32(self[offset]) << 24 |
                   UInt32(self[offset + 1]) << 16 |
                   UInt32(self[offset + 2]) << 8 |
                   UInt32(self[offset + 3])
        offset += 4
        return value
    }
    
    func readUInt64(at offset: inout Int) -> UInt64? {
        guard offset + 8 <= self.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 {
            value = (value << 8) | UInt64(self[offset + i])
        }
        offset += 8
        return value
    }
    
    func readString(at offset: inout Int, maxLength: Int = 255) -> String? {
        let length: Int
        
        if maxLength <= 255 {
            guard let len = readUInt8(at: &offset) else { return nil }
            length = Int(len)
        } else {
            guard let len = readUInt16(at: &offset) else { return nil }
            length = Int(len)
        }
        
        guard offset + length <= self.count else { return nil }
        
        let stringData = self[offset..<offset + length]
        offset += length
        
        return String(data: stringData, encoding: .utf8)
    }
    
    func readData(at offset: inout Int, maxLength: Int = 65535) -> Data? {
        let length: Int
        
        if maxLength <= 255 {
            guard let len = readUInt8(at: &offset) else { return nil }
            length = Int(len)
        } else {
            guard let len = readUInt16(at: &offset) else { return nil }
            length = Int(len)
        }
        
        guard offset + length <= self.count else { return nil }
        
        let data = self[offset..<offset + length]
        offset += length
        
        return data
    }
    
    func readDate(at offset: inout Int) -> Date? {
        guard let timestamp = readUInt64(at: &offset) else { return nil }
        return Date(timeIntervalSince1970: Double(timestamp) / 1000.0)
    }
    
    func readUUID(at offset: inout Int) -> String? {
        guard offset + 16 <= self.count else { return nil }
        
        let uuidData = self[offset..<offset + 16]
        offset += 16
        
        // Convert 16 bytes to UUID string format
        let uuid = uuidData.map { String(format: "%02x", $0) }.joined()
        
        // Insert hyphens at proper positions: 8-4-4-4-12
        var result = ""
        for (index, char) in uuid.enumerated() {
            if index == 8 || index == 12 || index == 16 || index == 20 {
                result += "-"
            }
            result.append(char)
        }
        
        return result.uppercased()
    }
    
    func readFixedBytes(at offset: inout Int, count: Int) -> Data? {
        guard offset + count <= self.count else { return nil }
        
        let data = self[offset..<offset + count]
        offset += count
        
        return data
    }
}

// MARK: - Binary Message Protocol

protocol BinaryEncodable {
    func toBinaryData() -> Data
    static func fromBinaryData(_ data: Data) -> Self?
}

// MARK: - Message Type Registry

enum BinaryMessageType: UInt8 {
    case deliveryAck = 0x01
    case readReceipt = 0x02
    case versionHello = 0x07
    case versionAck = 0x08
    case noiseIdentityAnnouncement = 0x09
    case noiseMessage = 0x0A
}