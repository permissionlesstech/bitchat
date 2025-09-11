//
// FileTransferService.swift
// bitchat
//
// Unified file transfer service for both mesh (Bluetooth) and off-mesh (Nostr) networks
// This is free and unencumbered software released into the public domain.
//

import Foundation
import UniformTypeIdentifiers

/// File transfer destination for both mesh and Nostr networks
enum FileTransferDestination {
    case meshPrivateChat(peerID: String)
    case locationChannel(geohash: String)
}

/// File transfer result
enum FileTransferResult {
    case success
    case failure(String)
}

/// File attachment structure for consistent TLV encoding
struct FileAttachment {
    let filename: String
    let mimeType: String
    let data: Data
    
    /// Encode file to TLV format: [filenameLen(2)][filename][mimeLen(2)][mime][dataLen(4)][bytes]
    func encodeTLV() -> Data {
        var payloadData = Data()
        let fnameBytes = Array(filename.utf8)
        let mimeBytes = Array(mimeType.utf8)
        
        // Use proper byte encoding to avoid alignment issues
        let fLen = UInt16(min(fnameBytes.count, 1024))
        let mLen = UInt16(min(mimeBytes.count, 256))
        let dLen = UInt32(data.count)
        
        // Encode lengths in big-endian format
        payloadData.append(UInt8(fLen >> 8))
        payloadData.append(UInt8(fLen & 0xFF))
        payloadData.append(contentsOf: fnameBytes.prefix(Int(fLen)))
        
        payloadData.append(UInt8(mLen >> 8))
        payloadData.append(UInt8(mLen & 0xFF))
        payloadData.append(contentsOf: mimeBytes.prefix(Int(mLen)))
        
        payloadData.append(UInt8(dLen >> 24))
        payloadData.append(UInt8((dLen >> 16) & 0xFF))
        payloadData.append(UInt8((dLen >> 8) & 0xFF))
        payloadData.append(UInt8(dLen & 0xFF))
        payloadData.append(data)
        
        return payloadData
    }
    
    /// Decode TLV format to file attachment
    static func decodeTLV(_ data: Data) -> FileAttachment? {
        guard data.count >= 8 else { return nil }
        
        var offset = 0
        
        // Read filename length (big-endian)
        guard offset + 2 <= data.count else { return nil }
        let fLen = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        
        guard offset + Int(fLen) <= data.count else { return nil }
        let filename = String(data: data.subdata(in: offset..<offset + Int(fLen)), encoding: .utf8) ?? ""
        offset += Int(fLen)
        
        // Read mime type length (big-endian)
        guard offset + 2 <= data.count else { return nil }
        let mLen = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        
        guard offset + Int(mLen) <= data.count else { return nil }
        let mimeType = String(data: data.subdata(in: offset..<offset + Int(mLen)), encoding: .utf8) ?? "application/octet-stream"
        offset += Int(mLen)
        
        // Read file data length (big-endian)
        guard offset + 4 <= data.count else { return nil }
        let dLen = (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16) | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        offset += 4
        
        guard offset + Int(dLen) <= data.count else { return nil }
        let fileData = data.subdata(in: offset..<offset + Int(dLen))
        
        return FileAttachment(filename: filename, mimeType: mimeType, data: fileData)
    }
}

/// Unified file transfer service that handles both mesh and Nostr transfers
@MainActor
class FileTransferService: ObservableObject {
    
    // MARK: - Dependencies
    private weak var bleService: BLEService?
    private weak var nostrRelayManager: NostrRelayManager?
    private weak var locationChannelManager: LocationChannelManager?
    
    // MARK: - Published Properties
    @Published var isTransferring = false
    @Published var transferProgress: Double = 0.0
    @Published var lastError: String?
    
    // MARK: - Initialization
    init(bleService: BLEService? = nil, 
         nostrRelayManager: NostrRelayManager? = nil,
         locationChannelManager: LocationChannelManager? = nil) {
        self.bleService = bleService
        self.nostrRelayManager = nostrRelayManager
        self.locationChannelManager = locationChannelManager
    }
    
    // MARK: - Public Interface
    
    /// Transfer a file to specified destination
    func transferFile(
        url: URL,
        to destination: FileTransferDestination,
        completion: @escaping (FileTransferResult) -> Void
    ) {
        guard !isTransferring else {
            completion(.failure("Transfer already in progress"))
            return
        }
        
        // Validate file
        do {
            let data = try Data(contentsOf: url)
            guard data.count > 0 && data.count <= NoiseSecurityConstants.maxMessageSize else {
                completion(.failure("File too large. Max \(NoiseSecurityConstants.maxMessageSize / (1024 * 1024))MB supported."))
                return
            }
            
            let filename = url.lastPathComponent
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let attachment = FileAttachment(filename: filename, mimeType: mimeType, data: data)
            
            isTransferring = true
            transferProgress = 0.0
            lastError = nil
            
            switch destination {
            case .meshPrivateChat(let peerID):
                transferViaMesh(attachment: attachment, toPeer: peerID, completion: completion)
            case .locationChannel(let geohash):
                transferViaNostr(attachment: attachment, toGeohash: geohash, completion: completion)
            }
            
        } catch {
            completion(.failure("Failed to read file: \(error.localizedDescription)"))
        }
    }
    
    // MARK: - Private Methods
    
    /// Transfer file via mesh (Bluetooth) to a specific peer
    private func transferViaMesh(
        attachment: FileAttachment,
        toPeer peerID: String,
        completion: @escaping (FileTransferResult) -> Void
    ) {
        guard let bleService = bleService else {
            finishTransfer(result: .failure("Mesh service not available"), completion: completion)
            return
        }
        
        // Use existing BLEService inline file transfer
        bleService.sendInlineFile(
            to: peerID,
            filename: attachment.filename,
            mimeType: attachment.mimeType,
            data: attachment.data
        )
        
        // BLEService doesn't provide async feedback, so we simulate progress
        simulateProgress {
            self.finishTransfer(result: .success, completion: completion)
        }
    }
    
    /// Transfer file via Nostr to a geohash location channel
    private func transferViaNostr(
        attachment: FileAttachment,
        toGeohash geohash: String,
        completion: @escaping (FileTransferResult) -> Void
    ) {
        guard let nostrRelayManager = nostrRelayManager else {
            finishTransfer(result: .failure("Nostr service not available"), completion: completion)
            return
        }
        
        Task {
            do {
                // Create file transfer event content (base64-encoded file data)
                let encodedData = attachment.data.base64EncodedString()
                let fileContent = [
                    "type": "file",
                    "filename": attachment.filename,
                    "mimeType": attachment.mimeType,
                    "size": attachment.data.count,
                    "data": encodedData
                ]
                
                guard let contentData = try? JSONSerialization.data(withJSONObject: fileContent),
                      let contentString = String(data: contentData, encoding: .utf8) else {
                    await MainActor.run {
                        self.finishTransfer(result: .failure("Failed to encode file content"), completion: completion)
                    }
                    return
                }
                
                // Get identity for this geohash
                let identity = try NostrIdentityBridge.deriveIdentity(forGeohash: geohash)
                
                // Create geohash file transfer event (kind 20001)
                let event = try NostrProtocol.createEphemeralGeohashFileEvent(
                    fileContent: contentString,
                    geohash: geohash,
                    senderIdentity: identity,
                    filename: attachment.filename
                )
                
                // Get target relays for this geohash
                let targetRelays = await GeoRelayDirectory.shared.closestRelays(
                    toGeohash: geohash,
                    count: 3
                )
                
                if targetRelays.isEmpty {
                    await MainActor.run {
                        self.finishTransfer(result: .failure("No relays available for location \(geohash)"), completion: completion)
                    }
                    return
                }
                
                // Send to relays
                await nostrRelayManager.sendEvent(event, to: targetRelays)
                
                await MainActor.run {
                    self.simulateProgress {
                        self.finishTransfer(result: .success, completion: completion)
                    }
                }
                
            } catch {
                await MainActor.run {
                    self.finishTransfer(result: .failure("Failed to send file: \(error.localizedDescription)"), completion: completion)
                }
            }
        }
    }
    
    /// Simulate transfer progress for UI feedback
    private func simulateProgress(completion: @escaping () -> Void) {
        let steps = 10
        let delay = 0.1
        
        func updateProgress(step: Int) {
            transferProgress = Double(step) / Double(steps)
            
            if step >= steps {
                completion()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    updateProgress(step: step + 1)
                }
            }
        }
        
        updateProgress(step: 0)
    }
    
    /// Complete the transfer process
    private func finishTransfer(
        result: FileTransferResult,
        completion: @escaping (FileTransferResult) -> Void
    ) {
        isTransferring = false
        transferProgress = 1.0
        
        switch result {
        case .success:
            lastError = nil
        case .failure(let error):
            lastError = error
        }
        
        completion(result)
        
        // Reset UI state after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.transferProgress = 0.0
        }
    }
}
