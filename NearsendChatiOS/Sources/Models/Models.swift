import Foundation

struct Peer: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var hops: Int          // 1 = direct BLE link, >1 = relayed through other phones
    var rssi: Int          // dBm, used for radar distance
    var verified: Bool = false
    var fingerprint: String = ""
}

enum DeliveryState: String, Codable { case sending, sent, relayed, delivered, failed }

struct Message: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var text: String
    var date: Date
    var mine: Bool
    var state: DeliveryState = .delivered
    var hops: Int = 1
    var sender: String? = nil      // shown on public-channel messages
}

struct Conversation: Identifiable, Codable {
    let id: String
    var peer: Peer
    var messages: [Message]
    var unread: Int = 0
    var last: Message? { messages.last }
}

/// The public "everyone nearby" channel lives in a conversation with this id.
let publicChannelID = "public"
