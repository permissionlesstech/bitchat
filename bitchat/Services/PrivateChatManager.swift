//
// PrivateChatManager.swift
// bitchat
//
// Manages private chat sessions and messages
// This is free and unencumbered software released into the public domain.
//

import BitLogger
import Foundation
import SwiftUI

/// Manages private conversation state and reconciliation.
final class PrivateConversationsStore: ObservableObject, PrivateConversationsStoreProtocol {
    @Published var privateChats: [PeerID: [BitchatMessage]] = [:]
    @Published var selectedPeer: PeerID? = nil
    @Published var unreadMessages: Set<PeerID> = []

    private var selectedPeerFingerprint: String? = nil
    var hasSelectedPeerFingerprint: Bool { selectedPeerFingerprint != nil }
    var sentReadReceipts: Set<String> = [] {
        didSet {
            guard persistReadReceipts, oldValue != sentReadReceipts else { return }
            if let data = try? JSONEncoder().encode(Array(sentReadReceipts)) {
                readReceiptsDefaults.set(data, forKey: Self.sentReadReceiptsDefaultsKey)
            } else {
                SecureLogger.error("❌ Failed to encode read receipts for persistence", category: .session)
            }
        }
    }

    weak var meshService: Transport?
    // Route acks/receipts via MessageRouter (chooses mesh or Nostr)
    weak var messageRouter: MessageRouter?
    // Peer service for looking up peer info during consolidation
    weak var unifiedPeerService: UnifiedPeerService?

    private let persistReadReceipts: Bool
    private let readReceiptsDefaults: UserDefaults

    private static let sentReadReceiptsDefaultsKey = "sentReadReceipts"

    init(
        meshService: Transport? = nil,
        persistReadReceipts: Bool = false,
        readReceiptsDefaults: UserDefaults = .standard
    ) {
        self.meshService = meshService
        self.persistReadReceipts = persistReadReceipts
        self.readReceiptsDefaults = readReceiptsDefaults

        guard persistReadReceipts,
              let data = readReceiptsDefaults.data(forKey: Self.sentReadReceiptsDefaultsKey),
              let receipts = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }

        sentReadReceipts = Set(receipts)
    }

    // Cap for messages stored per private chat
    private let privateChatCap = TransportConfig.privateChatCap

    func messages(for peerID: PeerID) -> [BitchatMessage] {
        privateChats[peerID] ?? []
    }

    func containsMessage(_ messageID: String, targetPeerID: PeerID? = nil) -> Bool {
        if let targetPeerID {
            return privateChats[targetPeerID]?.contains(where: { $0.id == messageID }) == true
        }
        return privateChats.values.contains { messages in
            messages.contains(where: { $0.id == messageID })
        }
    }

    func upsertMessage(_ message: BitchatMessage, for peerID: PeerID) {
        mutateChats { chats in
            var messages = chats[peerID] ?? []
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index] = message
            } else {
                messages.append(message)
            }
            messages.sort { $0.timestamp < $1.timestamp }
            chats[peerID] = Array(messages.suffix(privateChatCap))
        }
    }

    func ensureConversation(for peerID: PeerID) {
        mutateChats { chats in
            if chats[peerID] == nil {
                chats[peerID] = []
            }
        }
    }

    func removeConversation(for peerID: PeerID) {
        mutateChats { chats in
            chats.removeValue(forKey: peerID)
        }
    }

    @discardableResult
    func mergeConversation(
        from sourcePeerID: PeerID,
        into targetPeerID: PeerID,
        transform: (BitchatMessage) -> BitchatMessage = { $0 },
        removeSource: Bool = true
    ) -> Int {
        guard sourcePeerID != targetPeerID else { return 0 }

        var mergedCount = 0
        mutateChats { chats in
            guard let sourceMessages = chats[sourcePeerID], !sourceMessages.isEmpty else {
                return
            }

            var targetMessages = chats[targetPeerID] ?? []
            var existingMessageIDs = Set(targetMessages.map(\.id))

            for message in sourceMessages {
                let updated = transform(message)
                if existingMessageIDs.insert(updated.id).inserted {
                    targetMessages.append(updated)
                    mergedCount += 1
                }
            }

            targetMessages.sort { $0.timestamp < $1.timestamp }
            chats[targetPeerID] = Array(targetMessages.suffix(privateChatCap))

            if removeSource {
                chats.removeValue(forKey: sourcePeerID)
            }
        }

        return mergedCount
    }

    func markUnread(for peerID: PeerID) {
        var unread = unreadMessages
        unread.insert(peerID)
        unreadMessages = unread
    }

    func clearUnread(for peerID: PeerID) {
        guard unreadMessages.contains(peerID) else { return }
        var unread = unreadMessages
        unread.remove(peerID)
        unreadMessages = unread
    }

    func migrateUnread(from sourcePeerID: PeerID, to targetPeerID: PeerID) {
        guard unreadMessages.contains(sourcePeerID) else { return }
        var unread = unreadMessages
        unread.remove(sourcePeerID)
        unread.insert(targetPeerID)
        unreadMessages = unread
    }

    func hasMessages(for peerID: PeerID) -> Bool {
        !(privateChats[peerID] ?? []).isEmpty
    }

    @MainActor
    func combinedMessages(for peerID: PeerID) -> [BitchatMessage] {
        var combined: [BitchatMessage] = privateChats[peerID] ?? []

        if peerID.bare.count == 16,
           let peer = unifiedPeerService?.getPeer(by: peerID) {
            let stablePeerID = PeerID(hexData: peer.noisePublicKey)
            if stablePeerID != peerID {
                combined.append(contentsOf: privateChats[stablePeerID] ?? [])
            }
        } else if peerID.bare.count == 64 {
            let shortPeerID = peerID.toShort()
            if shortPeerID != peerID {
                combined.append(contentsOf: privateChats[shortPeerID] ?? [])
            }
        }

        var bestByID: [String: BitchatMessage] = [:]
        for message in combined {
            if let existing = bestByID[message.id] {
                let existingRank = deliveryStatusRank(existing.deliveryStatus)
                let nextRank = deliveryStatusRank(message.deliveryStatus)
                if nextRank > existingRank || (nextRank == existingRank && message.timestamp > existing.timestamp) {
                    bestByID[message.id] = message
                }
            } else {
                bestByID[message.id] = message
            }
        }

        return bestByID.values.sorted { $0.timestamp < $1.timestamp }
    }

    @MainActor
    func hasUnreadMessages(for peerID: PeerID) -> Bool {
        if unreadMessages.contains(peerID) {
            return true
        }

        if peerID.bare.count == 16,
           let peer = unifiedPeerService?.getPeer(by: peerID) {
            let stablePeerID = PeerID(hexData: peer.noisePublicKey)
            if unreadMessages.contains(stablePeerID) {
                return true
            }

            if let nostrHex = peer.nostrPublicKey {
                let conversationPeerID = PeerID(nostr_: nostrHex)
                if unreadMessages.contains(conversationPeerID) {
                    return true
                }
            }
        } else if peerID.bare.count == 64 {
            let shortPeerID = peerID.toShort()
            if unreadMessages.contains(shortPeerID) {
                return true
            }
        }

        let peerNickname = (
            meshService?.peerNickname(peerID: peerID) ??
            unifiedPeerService?.getPeer(by: peerID)?.nickname ??
            ""
        ).lowercased()

        guard !peerNickname.isEmpty else {
            return false
        }

        for unreadPeerID in unreadMessages where unreadPeerID.isGeoDM {
            if let firstMessage = privateChats[unreadPeerID]?.first,
               firstMessage.sender.lowercased() == peerNickname {
                return true
            }
        }

        return false
    }

    @MainActor
    func mostRelevantPeerID() -> PeerID? {
        let unreadSorted = unreadMessages
            .map { ($0, privateChats[$0]?.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.1 > $1.1 }

        if let targetPeerID = unreadSorted.first?.0 {
            return targetPeerID
        }

        return privateChats
            .map { (id: $0.key, ts: $0.value.last?.timestamp ?? Date.distantPast) }
            .sorted { $0.ts > $1.ts }
            .first?.id
    }

    @discardableResult
    func removeMessage(withID id: String) -> BitchatMessage? {
        var removedMessage: BitchatMessage?
        var emptiedPeerIDs: [PeerID] = []

        mutateChats { chats in
            for (peerID, messages) in chats {
                let filtered = messages.filter { $0.id != id }
                guard filtered.count != messages.count else { continue }

                if removedMessage == nil {
                    removedMessage = messages.first(where: { $0.id == id })
                }

                if filtered.isEmpty {
                    chats.removeValue(forKey: peerID)
                    emptiedPeerIDs.append(peerID)
                } else {
                    chats[peerID] = filtered
                }
            }
        }

        guard !emptiedPeerIDs.isEmpty else {
            return removedMessage
        }

        var unread = unreadMessages
        for peerID in emptiedPeerIDs {
            unread.remove(peerID)
        }
        unreadMessages = unread

        return removedMessage
    }

    func clearAll() {
        privateChats = [:]
        unreadMessages = []
        selectedPeer = nil
        selectedPeerFingerprint = nil
        sentReadReceipts.removeAll()
    }

    @discardableResult
    func updateMessage(
        id: String,
        in peerID: PeerID,
        transform: (BitchatMessage) -> BitchatMessage
    ) -> Bool {
        var updated = false
        mutateChats { chats in
            guard var messages = chats[peerID],
                  let index = messages.firstIndex(where: { $0.id == id }) else {
                return
            }
            messages[index] = transform(messages[index])
            chats[peerID] = messages
            updated = true
        }
        return updated
    }

    @discardableResult
    func updateDeliveryStatus(
        _ status: DeliveryStatus,
        forMessageID messageID: String,
        in peerID: PeerID
    ) -> Bool {
        updateMessage(id: messageID, in: peerID) { $0.withDeliveryStatus(status) }
    }

    @discardableResult
    func updateDeliveryStatus(
        _ status: DeliveryStatus,
        forMessageID messageID: String
    ) -> (peerID: PeerID, index: Int)? {
        var result: (peerID: PeerID, index: Int)?
        mutateChats { chats in
            for (peerID, messages) in chats {
                guard let index = messages.firstIndex(where: { $0.id == messageID }) else { continue }
                var updated = messages
                updated[index] = updated[index].withDeliveryStatus(status)
                chats[peerID] = updated
                result = (peerID, index)
                return
            }
        }
        return result
    }

    // MARK: - Message Consolidation

    /// Consolidates messages from different peer ID representations into a single chat.
    /// This ensures messages from stable Noise keys and temporary Nostr peer IDs are merged.
    /// - Parameters:
    ///   - peerID: The target peer ID to consolidate messages into
    ///   - peerNickname: The peer's display name (lowercased for matching)
    ///   - persistedReadReceipts: The persisted read receipts set from ChatViewModel (UserDefaults-backed)
    /// - Returns: True if any unread messages were found during consolidation
    @MainActor
    func consolidateMessages(for peerID: PeerID, peerNickname: String) -> Bool {
        guard let meshService = meshService else { return false }
        var hasUnreadMessages = false
        var chats = privateChats
        var unread = unreadMessages

        // 1. Consolidate from stable Noise key (64-char hex)
        if let peer = unifiedPeerService?.getPeer(by: peerID) {
            let noiseKeyHex = PeerID(hexData: peer.noisePublicKey)

            if noiseKeyHex != peerID, let nostrMessages = chats[noiseKeyHex], !nostrMessages.isEmpty {
                if chats[peerID] == nil {
                    chats[peerID] = []
                }

                let existingMessageIds = Set(chats[peerID]?.map { $0.id } ?? [])
                for message in nostrMessages {
                    if !existingMessageIds.contains(message.id) {
                        let updatedMessage = message.withSenderPeerID(
                            message.senderPeerID == meshService.myPeerID ? meshService.myPeerID : peerID
                        )
                        chats[peerID, default: []].append(updatedMessage)

                        if message.senderPeerID != meshService.myPeerID {
                            let messageAge = Date().timeIntervalSince(message.timestamp)
                            if messageAge < 60 && !sentReadReceipts.contains(message.id) {
                                hasUnreadMessages = true
                            }
                        }
                    }
                }

                chats[peerID]?.sort { $0.timestamp < $1.timestamp }

                if hasUnreadMessages {
                    unread.insert(peerID)
                } else if unread.contains(noiseKeyHex) {
                    unread.remove(noiseKeyHex)
                }

                chats.removeValue(forKey: noiseKeyHex)
            }
        }

        // 2. Consolidate from temporary Nostr peer IDs (nostr_* prefixed)
        let normalizedNickname = peerNickname.lowercased()
        var tempPeerIDsToConsolidate: [PeerID] = []

        for (storedPeerID, messages) in chats {
            if storedPeerID.isGeoDM && storedPeerID != peerID {
                let nicknamesMatch = messages.allSatisfy { $0.sender.lowercased() == normalizedNickname }
                if nicknamesMatch && !messages.isEmpty {
                    tempPeerIDsToConsolidate.append(storedPeerID)
                }
            }
        }

        if !tempPeerIDsToConsolidate.isEmpty {
            if chats[peerID] == nil {
                chats[peerID] = []
            }

            let existingMessageIds = Set(chats[peerID]?.map { $0.id } ?? [])
            var consolidatedCount = 0
            var hadUnreadTemp = false

            for tempPeerID in tempPeerIDsToConsolidate {
                if unread.contains(tempPeerID) {
                    hadUnreadTemp = true
                }

                if let tempMessages = chats[tempPeerID] {
                    for message in tempMessages {
                        if !existingMessageIds.contains(message.id) {
                            chats[peerID, default: []].append(message.withSenderPeerID(peerID))
                            consolidatedCount += 1
                        }
                    }
                    chats.removeValue(forKey: tempPeerID)
                    unread.remove(tempPeerID)
                }
            }

            if hadUnreadTemp {
                unread.insert(peerID)
                hasUnreadMessages = true
                SecureLogger.debug("📬 Transferred unread status from temp peer IDs to \(peerID)", category: .session)
            }

            if consolidatedCount > 0 {
                chats[peerID]?.sort { $0.timestamp < $1.timestamp }
                SecureLogger.info("📥 Consolidated \(consolidatedCount) Nostr messages from temporary peer IDs to \(peerNickname)", category: .session)
            }
        }

        privateChats = chats
        unreadMessages = unread
        return hasUnreadMessages
    }

    /// Syncs the read receipt tracking between manager and view model for sent messages
    @MainActor
    func syncReadReceiptsForSentMessages(peerID: PeerID, nickname: String) {
        guard let messages = privateChats[peerID] else { return }

        for message in messages {
            if message.sender == nickname {
                if let status = message.deliveryStatus {
                    switch status {
                    case .read, .delivered:
                        sentReadReceipts.insert(message.id)
                    case .failed, .partiallyDelivered, .sending, .sent:
                        break
                    }
                }
            }
        }
    }
    
    /// Start a private chat with a peer
    func startChat(with peerID: PeerID) {
        selectedPeer = peerID
        
        // Store fingerprint for persistence across reconnections
        if let fingerprint = meshService?.getFingerprint(for: peerID) {
            selectedPeerFingerprint = fingerprint
        }
        
        // Mark messages as read
        markAsRead(from: peerID)
        
        // Initialize chat if needed
        mutateChats { chats in
            if chats[peerID] == nil {
                chats[peerID] = []
            }
        }
    }
    
    /// End the current private chat
    func endChat() {
        selectedPeer = nil
        selectedPeerFingerprint = nil
    }

    @discardableResult
    func reconcileSelectedPeerForCurrentFingerprint() -> PeerID? {
        guard let selectedPeerFingerprint else { return selectedPeer }
        guard let meshService else { return selectedPeer }

        let currentPeerIDs = Set(meshService.currentPeerSnapshots().map(\.peerID))
        guard let currentPeerID = currentPeerIDs.first(where: { meshService.getFingerprint(for: $0) == selectedPeerFingerprint }) else {
            return selectedPeer
        }

        if let oldPeerID = selectedPeer, oldPeerID != currentPeerID {
            _ = mergeConversation(from: oldPeerID, into: currentPeerID)
            migrateUnread(from: oldPeerID, to: currentPeerID)
            selectedPeer = currentPeerID
        } else if selectedPeer == nil {
            selectedPeer = currentPeerID
        }

        clearUnread(for: currentPeerID)
        return currentPeerID
    }

    func selectPeerForContinuity(_ peerID: PeerID) {
        selectedPeer = peerID
    }

    func migrateSelectedPeerOnDisconnect(from peerID: PeerID, to stableKeyHex: PeerID, myPeerID: PeerID) {
        guard selectedPeer == peerID else { return }

        _ = mergeConversation(
            from: peerID,
            into: stableKeyHex,
            transform: { message in
                message.withSenderPeerID(
                    message.senderPeerID == myPeerID ? myPeerID : stableKeyHex
                )
            }
        )
        migrateUnread(from: peerID, to: stableKeyHex)
        selectedPeer = stableKeyHex
    }

    func clearSentReadReceipts(from senderPeerID: PeerID) {
        guard let messages = privateChats[senderPeerID], !messages.isEmpty else { return }
        let peerMessageIDs = Set(
            messages
                .filter { $0.senderPeerID == senderPeerID }
                .map(\.id)
        )
        guard !peerMessageIDs.isEmpty else { return }
        sentReadReceipts.subtract(peerMessageIDs)
    }

    @discardableResult
    func cleanupStaleUnreadPeerIDs(currentPeerIDs: Set<PeerID>) -> Int {
        let staleIDs = unreadMessages.subtracting(currentPeerIDs)
        guard !staleIDs.isEmpty else { return 0 }

        var unread = unreadMessages
        var removedCount = 0

        for staleID in staleIDs {
            if staleID.isGeoDM, let messages = privateChats[staleID], !messages.isEmpty {
                continue
            }

            if staleID.isNoiseKeyHex, let messages = privateChats[staleID], !messages.isEmpty {
                continue
            }

            unread.remove(staleID)
            removedCount += 1
        }

        if removedCount > 0 {
            unreadMessages = unread
        }

        return removedCount
    }

    @MainActor
    func findMessagePeerID(messageID: String, near peerID: PeerID) -> PeerID? {
        if privateChats[peerID]?.contains(where: { $0.id == messageID }) == true {
            return peerID
        }

        if peerID.isNoiseKeyHex {
            let shortPeerID = peerID.toShort()
            if privateChats[shortPeerID]?.contains(where: { $0.id == messageID }) == true {
                return shortPeerID
            }
        } else if peerID.bare.count == 16,
                  let peer = unifiedPeerService?.getPeer(by: peerID),
                  !peer.noisePublicKey.isEmpty {
            let stablePeerID = PeerID(hexData: peer.noisePublicKey)
            if privateChats[stablePeerID]?.contains(where: { $0.id == messageID }) == true {
                return stablePeerID
            }
        }

        return privateChats.first(where: { $0.value.contains(where: { $0.id == messageID }) })?.key
    }

    @discardableResult
    func cleanupOldReadReceipts(isStartupPhase: Bool) -> Int {
        if isStartupPhase || privateChats.isEmpty {
            return 0
        }

        let validMessageIDs = Set(
            privateChats.values
                .flatMap { $0 }
                .map(\.id)
        )

        let oldCount = sentReadReceipts.count
        sentReadReceipts = sentReadReceipts.intersection(validMessageIDs)
        return oldCount - sentReadReceipts.count
    }

    /// Remove duplicate messages by ID and keep chronological order
    func sanitizeChat(for peerID: PeerID) {
        guard let arr = privateChats[peerID] else { return }
        if arr.count <= 1 {
            return
        }

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(arr.count)
        var deduped: [BitchatMessage] = []
        deduped.reserveCapacity(arr.count)

        for msg in arr.sorted(by: { $0.timestamp < $1.timestamp }) {
            if let existing = indexByID[msg.id] {
                deduped[existing] = msg
            } else {
                indexByID[msg.id] = deduped.count
                deduped.append(msg)
            }
        }

        mutateChats { chats in
            chats[peerID] = deduped
        }
    }
    
    /// Mark messages from a peer as read
    func markAsRead(from peerID: PeerID) {
        if unreadMessages.contains(peerID) {
            var unread = unreadMessages
            unread.remove(peerID)
            unreadMessages = unread
        }
        
        // Send read receipts for unread messages that haven't been sent yet
        if let messages = privateChats[peerID] {
            for message in messages {
                if message.senderPeerID == peerID && !message.isRelay && !sentReadReceipts.contains(message.id) {
                    sendReadReceipt(for: message)
                }
            }
        }
    }
    
    // MARK: - Private Methods

    private func mutateChats(_ transform: (inout [PeerID: [BitchatMessage]]) -> Void) {
        var chats = privateChats
        transform(&chats)
        privateChats = chats
    }

    private func deliveryStatusRank(_ status: DeliveryStatus?) -> Int {
        guard let status else { return 0 }

        switch status {
        case .failed:
            return 1
        case .sending:
            return 2
        case .sent:
            return 3
        case .partiallyDelivered:
            return 4
        case .delivered:
            return 5
        case .read:
            return 6
        }
    }
    
    private func sendReadReceipt(for message: BitchatMessage) {
        guard !sentReadReceipts.contains(message.id),
              let senderPeerID = message.senderPeerID else {
            return
        }
        
        sentReadReceipts.insert(message.id)
        
        // Create read receipt using the simplified method
        let receipt = ReadReceipt(
            originalMessageID: message.id,
            readerID: meshService?.myPeerID ?? PeerID(str: ""),
            readerNickname: meshService?.myNickname ?? ""
        )
        
        // Route via MessageRouter to avoid handshakeRequired spam when session isn't established
        if let router = messageRouter {
            SecureLogger.debug("PrivateChatManager: sending READ ack for \(message.id.prefix(8))… to \(senderPeerID.id.prefix(8))… via router", category: .session)
            Task { @MainActor in
                router.sendReadReceipt(receipt, to: senderPeerID)
            }
        } else {
            // Fallback: preserve previous behavior
            meshService?.sendReadReceipt(receipt, to: senderPeerID)
        }
    }
}

typealias PrivateChatManager = PrivateConversationsStore
