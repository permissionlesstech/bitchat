//
// ChatViewModelMediaTargetTests.swift
// bitchatTests
//
// Voice notes, photos and push-to-talk bound to an explicit conversation,
// end to end through a real view model: each goes where the composer that
// made it points, whatever is selected by the time it is ready.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Testing
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import BitFoundation
@testable import bitchat

@MainActor
private func makeMediaTargetTestViewModel() -> (viewModel: ChatViewModel, transport: MockTransport) {
    let keychain = MockKeychain()
    let transport = MockTransport()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport
    )
    return (viewModel, transport)
}

@Suite(.serialized)
struct ChatViewModelMediaTargetTests {
    private let alice = PeerID(str: "a11ce000a11ce000")
    private let geohashChannel = GeohashChannel(level: .city, geohash: "u4pruy")

    // MARK: Voice and photos

    @Test @MainActor
    func meshVoiceNoteSenderPostsToMeshEvenIfTheSelectionMovesBeforeTheRelease() async throws {
        let (viewModel, transport) = makeMediaTargetTestViewModel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try Data("voice payload".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        viewModel.selectedPrivateChatPeer = alice
        let sendVoiceNote = viewModel.makeVoiceNoteSender(for: .mesh)
        // The person switches to a geohash before the file is finalized.
        viewModel.selectedPrivateChatPeer = nil
        viewModel.switchLocationChannel(to: .location(geohashChannel))
        sendVoiceNote(url)

        let didSend = await TestHelpers.waitUntil({ transport.sentBroadcastFiles.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.isEmpty)
        let posted = viewModel.publicMessages(for: .mesh).last
        #expect(posted?.content.contains("[voice]") == true)
        // Under the mesh identity it is broadcast with.
        #expect(posted?.senderPeerID == viewModel.meshService.myPeerID)
        #expect(!viewModel.publicMessages(for: .location(geohashChannel)).contains { $0.content.contains("[voice]") })
        #expect(viewModel.privateMessages(for: alice).isEmpty)
    }

    @Test @MainActor
    func aPhotoGoesToTheTargetItWasPickedFor() async throws {
        let (viewModel, transport) = makeMediaTargetTestViewModel()
        let sourceURL = try makeTargetTestImageURL()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        viewModel.selectedPrivateChatPeer = alice

        #if os(iOS)
        viewModel.processThenSendImage(UIImage(contentsOfFile: sourceURL.path), to: .mesh)
        #else
        viewModel.processThenSendImage(from: sourceURL, to: .mesh)
        #endif

        let didSend = await TestHelpers.waitUntil({ transport.sentBroadcastFiles.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(didSend)
        #expect(transport.sentPrivateFiles.isEmpty)
        #expect(viewModel.publicMessages(for: .mesh).last?.content.contains("[image]") == true)
        #expect(viewModel.privateMessages(for: alice).isEmpty)
    }

    // MARK: Push-to-talk

    @Test @MainActor
    func liveVoiceStreamsOnlyToTheTargetsOwnAudience() {
        let (viewModel, transport) = makeMediaTargetTestViewModel()
        let reachable = PeerID(str: "c0ffee00c0ffee00")
        transport.reachablePeers.insert(reachable)
        transport.peerNoiseStates[reachable] = .established
        transport.reachablePeers.insert(alice)
        viewModel.selectedPrivateChatPeer = reachable
        viewModel.activeChannel = .location(geohashChannel)

        // The setting is shared state: flip it and read synchronously so no
        // other main-actor test can observe the change.
        let previous = PTTSettings.liveVoiceEnabled
        PTTSettings.liveVoiceEnabled = true
        defer { PTTSettings.liveVoiceEnabled = previous }

        // #mesh broadcasts even with a DM open and a geohash selected.
        #expect(viewModel.liveVoiceTarget(for: .mesh) == .publicMesh)
        #expect(viewModel.makeVoiceCaptureSession(for: .mesh).isLive)
        // A DM streams only to its own peer, and only once it can hear it.
        #expect(viewModel.liveVoiceTarget(for: ConversationTarget(channel: .mesh, privatePeer: reachable)) == .peer(reachable))
        #expect(viewModel.liveVoiceTarget(for: ConversationTarget(channel: .mesh, privatePeer: alice)) == nil)
        // Geohash timelines and DMs, and groups, record classic notes.
        #expect(viewModel.liveVoiceTarget(for: .publicChannel(.location(geohashChannel))) == nil)
        #expect(!viewModel.makeVoiceCaptureSession(for: .publicChannel(.location(geohashChannel))).isLive)

        // No DM target, of any kind and in any scope, ever broadcasts.
        let dmPeers = [
            reachable,
            alice,
            PeerID(nostr_: String(repeating: "cd", count: 32)),
            PeerID(nostr: String(repeating: "ef", count: 32)),
            PeerID(groupID: Data(repeating: 0x42, count: 16))
        ]
        for peer in dmPeers {
            for scope in [ChannelID.mesh, .location(geohashChannel)] {
                #expect(viewModel.liveVoiceTarget(for: ConversationTarget(channel: scope, privatePeer: peer)) != .publicMesh)
            }
        }
    }
}

private func makeTargetTestImageURL() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("target-image-\(UUID().uuidString).png")
    #if os(iOS)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    guard let data = image.pngData() else { throw TargetTestImageError.encodingFailed }
    #else
    let image = NSImage(size: CGSize(width: 64, height: 64))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 64, height: 64)).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw TargetTestImageError.encodingFailed
    }
    #endif
    try data.write(to: url, options: .atomic)
    return url
}

private enum TargetTestImageError: Error {
    case encodingFailed
}
