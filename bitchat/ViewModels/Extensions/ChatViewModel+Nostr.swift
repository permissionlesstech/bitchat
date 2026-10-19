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
        nostrCoordinator.subscriptions.resubscribeCurrentGeohash()
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent) {
        nostrCoordinator.inbound.subscribeNostrEvent(event)
    }

    @MainActor
    func subscribeGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        nostrCoordinator.inbound.subscribeGiftWrap(giftWrap, id: id)
    }

    @MainActor
    func switchLocationChannel(to channel: ChannelID) {
        nostrCoordinator.subscriptions.switchLocationChannel(to: channel)
    }

    @MainActor
    func handleNostrEvent(_ event: NostrEvent) {
        nostrCoordinator.inbound.handleNostrEvent(event)
    }

    @MainActor
    func handleGiftWrap(_ giftWrap: NostrEvent, id: NostrIdentity) {
        nostrCoordinator.inbound.handleGiftWrap(giftWrap, id: id)
    }

    @MainActor
    func sendGeohash(context: GeoOutgoingContext) {
        nostrCoordinator.subscriptions.sendGeohash(context: context)
    }

    @MainActor
    func beginGeohashSampling(for geohashes: [String]) {
        nostrCoordinator.subscriptions.beginGeohashSampling(for: geohashes)
    }

    @MainActor
    func subscribeNostrEvent(_ event: NostrEvent, gh: String) {
        nostrCoordinator.presence.subscribeNostrEvent(event, gh: gh)
    }

    @MainActor
    func endGeohashSampling() {
        nostrCoordinator.subscriptions.endGeohashSampling()
    }

    @MainActor
    func setupNostrMessageHandling() {
        if favoritesService.canActivateDoubleRatchetRelay,
           let currentIdentity = try? idBridge.getCurrentNostrIdentity()
        {
            ndrService.configureIfNeeded(
                identity: currentIdentity,
                processPendingActions: false
            )
            if ndrService.isRolloutEnabled {
                for relationship in favoritesService.favorites.values {
                    guard let peerNostrPublicKey =
                            relationship.peerNostrPublicKey,
                          let peerPubkeyHex =
                            Self.ndrNostrPubkeyHex(
                                from: peerNostrPublicKey
                            ),
                          ndrService.hasPairwiseSession(
                            with: peerPubkeyHex
                          )
                    else {
                        continue
                    }
                    guard favoritesService.markNdrRequired(
                        for: relationship.peerNoisePublicKey
                    ) else {
                        ndrService.onDecryptedMessage = nil
                        nostrCoordinator.subscriptions
                            .setupNostrMessageHandling()
                        return
                    }
                }
            }
            guard favoritesService.canActivateDoubleRatchetRelay else {
                ndrService.onDecryptedMessage = nil
                nostrCoordinator.subscriptions.setupNostrMessageHandling()
                return
            }
            ndrService.onDecryptedMessage = { [weak self] message, completion in
                guard let self else {
                    completion(.retry)
                    return
                }
                self.nostrCoordinator.inbound.handleNdrDecryptedMessage(
                    message,
                    completion: completion
                )
            }
            ndrService.configureIfNeeded(identity: currentIdentity)
        } else {
            ndrService.onDecryptedMessage = nil
        }
        nostrCoordinator.subscriptions.setupNostrMessageHandling()
    }

    @MainActor
    func findNoiseKey(for nostrPubkey: String) -> Data? {
        nostrCoordinator.inbound.findNoiseKey(for: nostrPubkey)
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
