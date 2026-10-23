//
// ConversationUIModelTargetTests.swift
// bitchatTests
//
// The UI-facing target APIs on ConversationUIModel: what a composer or a
// list acts on is the conversation it names, whatever is selected.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import Testing
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import BitFoundation
@testable import bitchat

@MainActor
private func makeTargetUIModel() -> (ui: ConversationUIModel, viewModel: ChatViewModel, transport: MockTransport) {
    let suiteName = "ConversationUIModelTargetTests.\(UUID().uuidString)"
    let storage = UserDefaults(suiteName: suiteName) ?? .standard
    storage.removePersistentDomain(forName: suiteName)
    let locationManager = LocationChannelManager(storage: storage)
    let keychain = MockKeychain()
    let transport = MockTransport()
    let viewModel = ChatViewModel(
        keychain: keychain,
        idBridge: NostrIdentityBridge(keychain: MockKeychainHelper()),
        identityManager: MockIdentityManager(keychain),
        transport: transport,
        locationManager: locationManager
    )
    let privateModel = PrivateConversationModel(
        chatViewModel: viewModel,
        conversations: viewModel.conversations,
        locationChannelsModel: LocationChannelsModel(manager: locationManager)
    )
    let ui = ConversationUIModel(
        chatViewModel: viewModel,
        privateConversationModel: privateModel,
        conversations: viewModel.conversations
    )
    return (ui, viewModel, transport)
}

@Suite(.serialized)
struct ConversationUIModelTargetTests {
    private let alice = PeerID(str: "a11ce000a11ce000")
    private let bob = PeerID(str: "b0b0b0b0b0b0b0b0")
    private let geohash = GeohashChannel(level: .city, geohash: "u4pruy")

    @Test @MainActor
    func meshPaneActionsStayInMeshWhileADMIsOpen() async {
        let (ui, viewModel, transport) = makeTargetUIModel()
        transport.simulateConnect(bob, nickname: "bob")
        let resolved = await TestHelpers.waitUntil({
            viewModel.getPeerIDForNickname("bob", in: .mesh) == bob
        }, timeout: TestConstants.settleTimeout)
        #expect(resolved)
        viewModel.selectedPrivateChatPeer = alice

        ui.sendMessage("hi mesh", to: .mesh)
        ui.sendHug(to: "bob", in: .mesh)
        ui.sendSlap(to: "bob", in: .mesh)

        // Emotes run as commands after a hop.
        let emoted = await TestHelpers.waitUntil({ transport.sentMessages.count == 3 }, timeout: TestConstants.settleTimeout)
        #expect(emoted)
        #expect(transport.sentMessages.first?.content == "hi mesh")
        #expect(transport.sentMessages.dropFirst().allSatisfy { $0.content.hasPrefix("* ") })
        #expect(transport.sentPrivateMessages.isEmpty)
        #expect(viewModel.privateMessages(for: alice).isEmpty)

        ui.clearConversation(.mesh)
        let cleared = await TestHelpers.waitUntil({
            !viewModel.publicMessages(for: .mesh).contains { $0.content == "hi mesh" }
        }, timeout: TestConstants.settleTimeout)
        #expect(cleared)
        #expect(viewModel.selectedPrivateChatPeer == alice)
    }

    @Test @MainActor
    func aBlockConfirmsInTheConversationItCameFrom() async {
        let (ui, viewModel, _) = makeTargetUIModel()
        viewModel.selectedPrivateChatPeer = alice

        ui.block(peerID: bob, displayName: "bob", from: .mesh)

        #expect(viewModel.publicMessages(for: .mesh).last?.sender == "system")
        #expect(viewModel.privateMessages(for: alice).isEmpty)
    }

    @Test @MainActor
    func aResendGoesToTheDMItWasFailedIn() async {
        let (ui, viewModel, transport) = makeTargetUIModel()
        transport.connectedPeers.insert(bob)
        transport.peerNicknames[bob] = "bob"
        viewModel.selectedPrivateChatPeer = alice
        let failed = BitchatMessage(
            sender: viewModel.nickname,
            content: "try again",
            timestamp: Date(),
            isRelay: false,
            isPrivate: true,
            recipientNickname: "bob",
            senderPeerID: viewModel.meshService.myPeerID,
            deliveryStatus: .failed(reason: "test")
        )
        viewModel.seedPrivateChat([failed], for: bob)

        ui.resendFailedPrivateMessage(failed, in: ConversationTarget(channel: .mesh, privatePeer: bob))

        #expect(transport.sentPrivateMessages.map(\.peerID) == [bob])
        #expect(!viewModel.privateMessages(for: bob).contains { $0.id == failed.id })
        #expect(viewModel.privateMessages(for: alice).isEmpty)
    }

    @Test @MainActor
    func autocompleteIsTheComposersOwn() async {
        let (ui, viewModel, transport) = makeTargetUIModel()
        transport.simulateConnect(alice, nickname: "alice")
        let resolved = await TestHelpers.waitUntil({
            viewModel.getPeerIDForNickname("alice", in: .mesh) == alice
        }, timeout: TestConstants.settleTimeout)
        #expect(resolved)
        viewModel.activeChannel = .location(geohash)

        let state = ui.autocomplete(for: "hi @al", cursorPosition: 6, in: .mesh)
        #expect(state.suggestions == ["@alice"])
        #expect(!ui.showAutocomplete)

        var text = "hi @al"
        _ = ui.complete("@alice", in: &text, state: state)
        #expect(text == "hi @alice")
    }

    @Test @MainActor
    func voiceAndPhotosUseTheTargetsConversation() async throws {
        let (ui, viewModel, transport) = makeTargetUIModel()
        viewModel.selectedPrivateChatPeer = alice

        #expect(!ui.makeVoiceCaptureSession(for: .publicChannel(.location(geohash))).isLive)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ui-voice-\(UUID().uuidString).m4a")
        try Data("voice payload".utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        ui.makeVoiceNoteSender(for: .mesh)(url)
        let sentVoice = await TestHelpers.waitUntil({ transport.sentBroadcastFiles.count == 1 }, timeout: TestConstants.settleTimeout)
        #expect(sentVoice)

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("ui-image-\(UUID().uuidString).png")
        try makeUITargetImageData().write(to: imageURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        #if os(iOS)
        ui.processSelectedImage(UIImage(contentsOfFile: imageURL.path), to: .mesh)
        #else
        ui.processSelectedImage(from: imageURL, to: .mesh)
        #endif
        let sentImage = await TestHelpers.waitUntil({ transport.sentBroadcastFiles.count == 2 }, timeout: TestConstants.settleTimeout)
        #expect(sentImage)
        #expect(transport.sentPrivateFiles.isEmpty)
        #expect(viewModel.privateMessages(for: alice).isEmpty)
    }
}

private func makeUITargetImageData() throws -> Data {
    #if os(iOS)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
        UIColor.systemOrange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
    }
    guard let data = image.pngData() else { throw UITargetImageError.encodingFailed }
    return data
    #else
    let image = NSImage(size: CGSize(width: 48, height: 48))
    image.lockFocus()
    NSColor.systemOrange.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 48, height: 48)).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        throw UITargetImageError.encodingFailed
    }
    return data
    #endif
}

private enum UITargetImageError: Error {
    case encodingFailed
}
