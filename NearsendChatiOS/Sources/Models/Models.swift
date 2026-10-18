import Foundation

struct Peer: Identifiable, Hashable {
    let id: String
    var name: String
    var hops: Int          // 1 = direct BLE link, >1 = relayed
    var rssi: Int          // dBm, used for radar distance
    var verified: Bool = false
}

enum DeliveryState { case sending, sent, relayed, delivered }

struct Message: Identifiable, Hashable {
    let id = UUID()
    var text: String
    var date: Date
    var mine: Bool
    var state: DeliveryState = .delivered
    var hops: Int = 1
}

struct Conversation: Identifiable {
    let id: String
    var peer: Peer
    var messages: [Message]
    var unread: Int = 0
    var last: Message? { messages.last }
}
