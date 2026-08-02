import BitFoundation
import Foundation
import Testing
@testable import bitchat

struct PrivateImageNoiseEncryptionTests {
    @Test
    func privateImagePayloadIsNoiseEncryptedOnWireAndReassemblesByteIdentical() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(str: "0011223344556677")
        let bobPeerID = PeerID(str: "8899aabbccddeeff")
        try establishSessions(alice: alice, bob: bob, alicePeerID: alicePeerID, bobPeerID: bobPeerID)

        let marker = Data("PLAIN_IMAGE_MARKER_SHOULD_NOT_APPEAR_ON_WIRE".utf8)
        var imageBytes = Data(repeating: 0x7B, count: 70 * 1024)
        imageBytes.replaceSubrange(1024..<(1024 + marker.count), with: marker)

        let filePacket = BitchatFilePacket(
            fileName: "original.bin",
            fileSize: UInt64(imageBytes.count),
            mimeType: "image/png",
            content: imageBytes
        )
        let plaintext = try #require(BLENoisePayloadFactory.privateFileTransferPayload(filePacket, transferId: "tx-noise"))

        let ciphertext = try alice.encryptPrivateFilePayload(plaintext, for: alicePeerID)
        #expect(!ciphertext.containsSubsequence(marker))
        #expect(!ciphertext.containsSubsequence(imageBytes.prefix(64)))

        let decrypted = try bob.decrypt(ciphertext, from: bobPeerID)
        #expect(decrypted.first == NoisePayloadType.fileTransfer.rawValue)
        let decoded = try #require(PrivateFileTransferPacket.decode(Data(decrypted.dropFirst())))

        #expect(decoded.filePacket.content == imageBytes)
        #expect(decoded.filePacket.content.sha256Hash() == decoded.fileSHA256)
    }

    @Test
    func privateImageChunkCannotDecryptWithWrongNoiseSession() throws {
        let alice = NoiseEncryptionService(keychain: MockKeychain())
        let bob = NoiseEncryptionService(keychain: MockKeychain())
        let alicePeerID = PeerID(str: "0011223344556677")
        let bobPeerID = PeerID(str: "8899aabbccddeeff")
        try establishSessions(alice: alice, bob: bob, alicePeerID: alicePeerID, bobPeerID: bobPeerID)

        let wrongAlice = NoiseEncryptionService(keychain: MockKeychain())
        let wrongRecipient = NoiseEncryptionService(keychain: MockKeychain())
        let wrongAlicePeerID = PeerID(str: "1021324354657687")
        try establishSessions(alice: wrongAlice, bob: wrongRecipient, alicePeerID: wrongAlicePeerID, bobPeerID: bobPeerID)
        #expect(wrongRecipient.hasEstablishedSession(with: bobPeerID))

        let imageBytes = Data((0..<(32 * 1024)).map { UInt8($0 % 251) })
        let filePacket = BitchatFilePacket(
            fileName: "original.png",
            fileSize: UInt64(imageBytes.count),
            mimeType: "image/png",
            content: imageBytes
        )
        let plaintext = try #require(BLENoisePayloadFactory.privateFileTransferPayload(filePacket, transferId: "tx-wrong-key"))
        let ciphertext = try alice.encryptPrivateFilePayload(plaintext, for: alicePeerID)

        #expect(throws: (any Error).self) {
            _ = try wrongRecipient.decrypt(ciphertext, from: bobPeerID)
        }
    }

    private func establishSessions(
        alice: NoiseEncryptionService,
        bob: NoiseEncryptionService,
        alicePeerID: PeerID,
        bobPeerID: PeerID
    ) throws {
        let message1 = try alice.initiateHandshake(with: alicePeerID)
        let message2 = try #require(try bob.processHandshakeMessage(from: bobPeerID, message: message1))
        let message3 = try #require(try alice.processHandshakeMessage(from: alicePeerID, message: message2))
        let final = try bob.processHandshakeMessage(from: bobPeerID, message: message3)
        #expect(final == nil)
    }
}

private extension Data {
    func containsSubsequence<S: Sequence>(_ subsequence: S) -> Bool where S.Element == UInt8 {
        let needle = Array(subsequence)
        guard !needle.isEmpty, needle.count <= count else { return false }
        let haystack = Array(self)
        return haystack.indices.dropLast(needle.count - 1).contains { index in
            Array(haystack[index..<(index + needle.count)]) == needle
        }
    }
}
