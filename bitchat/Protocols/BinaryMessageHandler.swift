//
// BinaryMessageHandler.swift
// bitchat
//
// Unified binary message encoding/decoding handler
//

import Foundation

struct BinaryMessageHandler {
    
    // MARK: - Encoding
    
    static func encode(message: Any, type: MessageType) -> Data? {
        switch type {
        case .deliveryAck:
            return (message as? DeliveryAck)?.toBinaryData()
        case .readReceipt:
            return (message as? ReadReceipt)?.toBinaryData()
        case .channelKeyVerifyRequest:
            return (message as? ChannelKeyVerifyRequest)?.toBinaryData()
        case .channelKeyVerifyResponse:
            return (message as? ChannelKeyVerifyResponse)?.toBinaryData()
        case .channelPasswordUpdate:
            return (message as? ChannelPasswordUpdate)?.toBinaryData()
        case .channelMetadata:
            return (message as? ChannelMetadata)?.toBinaryData()
        case .versionHello:
            return (message as? VersionHello)?.toBinaryData()
        case .versionAck:
            return (message as? VersionAck)?.toBinaryData()
        case .noiseIdentityAnnounce:
            return (message as? NoiseIdentityAnnouncement)?.toBinaryData()
        case .noiseHandshakeInit, .noiseHandshakeResp:
            // Noise handshake messages are already binary
            return message as? Data
        case .noiseEncrypted:
            return (message as? NoiseMessage)?.toBinaryData()
        default:
            return nil
        }
    }
    
    // MARK: - Decoding
    
    static func decode(data: Data, type: MessageType) -> Any? {
        switch type {
        case .deliveryAck:
            return DeliveryAck.fromBinaryData(data)
        case .readReceipt:
            return ReadReceipt.fromBinaryData(data)
        case .channelKeyVerifyRequest:
            return ChannelKeyVerifyRequest.fromBinaryData(data)
        case .channelKeyVerifyResponse:
            return ChannelKeyVerifyResponse.fromBinaryData(data)
        case .channelPasswordUpdate:
            return ChannelPasswordUpdate.fromBinaryData(data)
        case .channelMetadata:
            return ChannelMetadata.fromBinaryData(data)
        case .versionHello:
            return VersionHello.fromBinaryData(data)
        case .versionAck:
            return VersionAck.fromBinaryData(data)
        case .noiseIdentityAnnounce:
            return NoiseIdentityAnnouncement.fromBinaryData(data)
        case .noiseHandshakeInit, .noiseHandshakeResp:
            // Noise handshake messages are already binary
            return data
        case .noiseEncrypted:
            return NoiseMessage.fromBinaryData(data)
        default:
            return nil
        }
    }
    
    // MARK: - Legacy JSON Support (for migration)
    
    static func decodeJSON(data: Data, type: MessageType) -> Any? {
        switch type {
        case .deliveryAck:
            return DeliveryAck.decode(from: data)
        case .readReceipt:
            return ReadReceipt.decode(from: data)
        case .channelKeyVerifyRequest:
            return ChannelKeyVerifyRequest.decode(from: data)
        case .channelKeyVerifyResponse:
            return ChannelKeyVerifyResponse.decode(from: data)
        case .channelPasswordUpdate:
            return ChannelPasswordUpdate.decode(from: data)
        case .channelMetadata:
            return ChannelMetadata.decode(from: data)
        case .versionHello:
            return VersionHello.decode(from: data)
        case .versionAck:
            return VersionAck.decode(from: data)
        case .noiseIdentityAnnounce:
            return NoiseIdentityAnnouncement.decode(from: data)
        case .noiseEncrypted:
            return NoiseMessage.decode(from: data)
        default:
            return nil
        }
    }
    
    // MARK: - Format Detection
    
    static func isBinaryFormat(_ data: Data) -> Bool {
        // Simple heuristic: JSON always starts with { or [
        guard let firstByte = data.first else { return false }
        return firstByte != 0x7B && firstByte != 0x5B // { and [
    }
    
    // MARK: - Unified Decode (with fallback)
    
    static func decodeWithFallback(data: Data, type: MessageType) -> Any? {
        // Try binary first
        if let result = decode(data: data, type: type) {
            return result
        }
        
        // Fallback to JSON for backward compatibility
        return decodeJSON(data: data, type: type)
    }
}