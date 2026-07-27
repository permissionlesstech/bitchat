import Foundation

struct ChatFavoriteStatusSnapshot: Equatable {
    let peerNickname: String
    let peerNostrPublicKey: String?
    let isFavorite: Bool
    let theyFavoritedUs: Bool

    init(
        peerNickname: String,
        peerNostrPublicKey: String?,
        isFavorite: Bool,
        theyFavoritedUs: Bool
    ) {
        self.peerNickname = peerNickname
        self.peerNostrPublicKey = peerNostrPublicKey
        self.isFavorite = isFavorite
        self.theyFavoritedUs = theyFavoritedUs
    }

    init(_ relationship: FavoritesPersistenceService.FavoriteRelationship) {
        self.peerNickname = relationship.peerNickname
        self.peerNostrPublicKey = relationship.peerNostrPublicKey
        self.isFavorite = relationship.isFavorite
        self.theyFavoritedUs = relationship.theyFavoritedUs
    }
}

enum ChatFavoritePersistenceAction: Equatable {
    case add(nickname: String, nostrKey: String?)
    case remove
}

enum ChatFavoriteNotificationDecision: Equatable {
    case none
    case send(isFavorite: Bool)
}

struct ChatFavoriteTogglePlan: Equatable {
    let persistenceAction: ChatFavoritePersistenceAction
    let notification: ChatFavoriteNotificationDecision
}

enum ChatFavoriteTogglePolicy {
    static func plan(
        currentStatus: ChatFavoriteStatusSnapshot?,
        fallbackNickname: String?,
        bridgedNostrKey: String?
    ) -> ChatFavoriteTogglePlan {
        let wasFavorite = currentStatus?.isFavorite ?? false

        if wasFavorite {
            return ChatFavoriteTogglePlan(
                persistenceAction: .remove,
                notification: .send(isFavorite: false)
            )
        }

        return ChatFavoriteTogglePlan(
            persistenceAction: .add(
                nickname: currentStatus?.peerNickname ?? fallbackNickname ?? "Unknown",
                nostrKey: currentStatus?.peerNostrPublicKey ?? bridgedNostrKey
            ),
            notification: currentStatus?.theyFavoritedUs == true ? .send(isFavorite: true) : .none
        )
    }
}
