package app.nearsend.chat

import java.util.UUID

data class Peer(
    val id: String,
    val name: String,
    val hops: Int,          // 1 = direct BLE link, >1 = relayed
    val rssi: Int,          // dBm, used for radar distance
    val verified: Boolean = false,
)

enum class Delivery { Sending, Sent, Relayed, Delivered, Failed }

data class Message(
    val text: String,
    val timeMs: Long,
    val mine: Boolean,
    val state: Delivery = Delivery.Delivered,
    val id: String = UUID.randomUUID().toString(),
)

data class Conversation(
    val id: String,
    val peer: Peer,
    val messages: List<Message>,
    val unread: Int = 0,
)
