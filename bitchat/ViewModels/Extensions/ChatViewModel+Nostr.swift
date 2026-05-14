//
// ChatViewModel+Nostr.swift
// bitchat
//
// Geohash and Nostr logic for ChatViewModel
//

import BitFoundation
import Foundation

extension ChatViewModel {

    @MainActor
    func resubscribeCurrentGeohash() {
        nostrCoordinator.resubscribeCurrentGeohash()
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent) {
        nostrCoordinator.subscribeNostrEvent(event)
    }

    @MainActor
    func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        nostrCoordinator.subscribeGiftWrap(giftWrap, id: id)
    }

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        nostrCoordinator.switchLocationChannel(to: channel)
    }

    @MainActor
    func handleNostrEvent(_ event: NostrEvent) {
        nostrCoordinator.handleNostrEvent(event)
    }

    @MainActor
    func subscribeToGeoChat(_ ch: GeohashChannel) {
        nostrCoordinator.subscribeToGeoChat(ch)
    }

    @MainActor
    func handleGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        nostrCoordinator.handleGiftWrap(giftWrap, id: id)
    }

    @MainActor
    func sendGeohash(context: GeoOutgoingContext) {
        nostrCoordinator.sendGeohash(context: context)
    }

    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        nostrCoordinator.beginGeohashSampling(for: geohashes)
    }

    @MainActor
    func subscribe(_ gh: String) {
        nostrCoordinator.subscribe(gh)
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent, gh: String) {
        nostrCoordinator.subscribeNostrEvent(event, gh: gh)
    }

    @MainActor
    func cooldownPerGeohash(_ gh: String, content: String, event: NostrEvent) {
        nostrCoordinator.cooldownPerGeohash(gh, content: content, event: event)
    }

    @MainActor
    func endGeohashSampling() {
        nostrCoordinator.endGeohashSampling()
    }

    @MainActor
    func setupNostrMessageHandling() {
        nostrCoordinator.setupNostrMessageHandling()
    }

    @MainActor
    func handleNostrMessage(_ giftWrap: NostrEvent) {
        nostrCoordinator.handleNostrMessage(giftWrap)
    }

    func processNostrMessage(_ giftWrap: NostrEvent) async {
        await nostrCoordinator.processNostrMessage(giftWrap)
    }

    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        nostrCoordinator.findNoiseKey(for: nostrPubkey)
    }

    @MainActor
    func sendDeliveryAckViaNostrEmbedded(
        _ message: BitchatMessage,
        wasReadBefore: Bool,
        senderPubkey: String,
        key: Data?
    ) {
        nostrCoordinator.sendDeliveryAckViaNostrEmbedded(
            message,
            wasReadBefore: wasReadBefore,
            senderPubkey: senderPubkey,
            key: key
        )
    }

    @MainActor
    func handleFavoriteNotification(content: String, from nostrPubkey: String) {
        nostrCoordinator.handleFavoriteNotification(content: content, from: nostrPubkey)
    }

    @MainActor
    func sendFavoriteNotificationViaNostr(noisePublicKey: Data, isFavorite: Bool) {
        nostrCoordinator.sendFavoriteNotificationViaNostr(noisePublicKey: noisePublicKey, isFavorite: isFavorite)
    }

    @MainActor
    func nostrPubkeyForDisplayName(_ name: String) -> String? {
        nostrCoordinator.nostrPubkeyForDisplayName(name)
    }

    @MainActor
    func startGeohashDM(withPubkeyHex hex: String) {
        nostrCoordinator.startGeohashDM(withPubkeyHex: hex)
    }

    @MainActor
    func fullNostrHex(forSenderPeerID senderID: PeerID) -> String? {
        nostrCoordinator.fullNostrHex(forSenderPeerID: senderID)
    }

    @MainActor
    func geohashDisplayName(for convKey: PeerID) -> String {
        nostrCoordinator.geohashDisplayName(for: convKey)
    }
}
