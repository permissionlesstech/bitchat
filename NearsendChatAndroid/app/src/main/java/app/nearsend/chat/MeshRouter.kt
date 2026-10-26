package app.nearsend.chat

import org.json.JSONObject
import java.util.Base64
import java.util.UUID

enum class SendOutcome { Sent, Unreachable, Failed }

/** Wire packet (JSON). See PROTOCOL.md. Optional fields are omitted when null. */
class Packet(
    val t: String,               // "ann" | "msg" | "pub" | "ack"
    val id: String,
    val src: String,
    val dst: String?,
    val ttl: Int,
    val ts: Long,
    val n: String? = null,       // sender nickname
    val pk: String? = null,      // ann: base64 X25519 public key
    val ct: String? = null,      // msg: base64 sealed text
    val tx: String? = null,      // pub: plain text
    val ref: String? = null,     // ack: id of the message being acknowledged
) {
    fun toBytes(): ByteArray {
        val o = JSONObject().put("v", 2).put("t", t).put("id", id).put("src", src)
        dst?.let { o.put("dst", it) }
        o.put("ttl", ttl).put("ts", ts)
        n?.let { o.put("n", it) }; pk?.let { o.put("pk", it) }; ct?.let { o.put("ct", it) }
        tx?.let { o.put("tx", it) }; ref?.let { o.put("ref", it) }
        return o.toString().toByteArray()
    }

    fun withTtl(newTtl: Int) = Packet(t, id, src, dst, newTtl, ts, n, pk, ct, tx, ref)

    companion object {
        fun parse(bytes: ByteArray): Packet? = runCatching {
            val o = JSONObject(String(bytes))
            if (o.getInt("v") != 2) return null
            fun opt(k: String) = if (o.has(k)) o.getString(k) else null
            Packet(o.getString("t"), o.getString("id"), o.getString("src"), opt("dst"), o.getInt("ttl"), o.getLong("ts"),
                opt("n"), opt("pk"), opt("ct"), opt("tx"), opt("ref"))
        }.getOrNull()
    }
}

/**
 * Multi-hop relay, identical in behaviour to the iOS router. Transport independent: the BLE layer (or a test harness)
 * feeds packets in and provides [transmit]. Peers announce themselves every few seconds; announcements, public messages and
 * direct messages are flooded with a hop limit and de-duplicated by packet id.
 */
class MeshRouter(val myId: String, var myName: String, private val crypto: MeshCrypto) {
    companion object {
        const val START_TTL = 5
        const val MAX_TEXT_BYTES = 180
        const val PEER_TIMEOUT_MS = 40_000L

        fun clip(s: String): String {
            val sb = StringBuilder(); var n = 0
            var i = 0
            while (i < s.length) {
                val cp = s.codePointAt(i); val len = String(Character.toChars(cp)).toByteArray().size
                if (n + len > MAX_TEXT_BYTES) break
                sb.appendCodePoint(cp); n += len; i += Character.charCount(cp)
            }
            return sb.toString()
        }
    }

    private class PeerInfo(val name: String, val pk: ByteArray, val hops: Int, val lastSeen: Long, val direct: Boolean)

    var now: () -> Long = { System.currentTimeMillis() }
    var transmit: ((link: String, data: ByteArray, done: (Boolean) -> Unit) -> Unit)? = null
    var onPeers: ((List<Peer>) -> Unit)? = null
    var onText: ((from: String, name: String, text: String, hops: Int, msgId: String) -> Unit)? = null
    var onPublic: ((from: String, name: String, text: String, id: String) -> Unit)? = null
    var onDelivered: ((msgId: String) -> Unit)? = null

    private val links = LinkedHashMap<String, String>()      // link id -> peer id (direct neighbours)
    private val peers = HashMap<String, PeerInfo>()
    private val rssi = HashMap<String, Int>()
    private val seen = HashSet<String>()
    private val seenOrder = ArrayDeque<String>()
    private val b64 = Base64.getEncoder()
    private val unb64 = Base64.getDecoder()

    // ---- neighbours

    fun neighborConnected(link: String, id: String, name: String, pk: ByteArray) {
        if (id == myId || pk.size != 32) return
        links[link] = id
        peers[id] = PeerInfo(name, pk, 1, now(), true)
        emitPeers()
        sendAnnounce(listOf(link))
    }

    fun neighborLost(link: String) {
        val id = links.remove(link) ?: return
        if (!links.containsValue(id)) { peers.remove(id); rssi.remove(id) }
        emitPeers()
    }

    fun updateRssi(link: String, value: Int) {
        val id = links[link] ?: return
        rssi[id] = value
        emitPeers()
    }

    // ---- periodic

    /** Call every ~8 seconds: floods our announcement and forgets relayed peers we stopped hearing about. */
    fun tick() {
        val cutoff = now() - PEER_TIMEOUT_MS
        val before = peers.size
        peers.entries.removeIf { !it.value.direct && it.value.lastSeen <= cutoff }
        if (peers.size != before) emitPeers()
        sendAnnounce(links.keys.toList())
    }

    private fun sendAnnounce(targets: List<String>) {
        val p = Packet("ann", UUID.randomUUID().toString(), myId, null, START_TTL, now(), n = myName, pk = b64.encodeToString(crypto.publicKey))
        remember(p.id)
        val data = p.toBytes()
        targets.forEach { transmit?.invoke(it, data) { } }
    }

    // ---- sending

    fun sendText(text: String, dst: String, msgId: String, completion: (SendOutcome) -> Unit) {
        val info = peers[dst] ?: return completion(SendOutcome.Unreachable)
        val ct = runCatching { crypto.seal(clip(text), info.pk, myId, dst, msgId) }.getOrNull() ?: return completion(SendOutcome.Failed)
        val p = Packet("msg", msgId, myId, dst, START_TTL, now(), n = myName, ct = b64.encodeToString(ct))
        remember(msgId)
        route(p, null, completion)
    }

    fun sendPublic(text: String, msgId: String, completion: (SendOutcome) -> Unit) {
        val p = Packet("pub", msgId, myId, null, START_TTL, now(), n = myName, tx = clip(text))
        remember(msgId)
        route(p, null, completion)
    }

    // ---- receiving

    fun receive(data: ByteArray, from: String?) {
        val p = Packet.parse(data) ?: return
        if (p.src == myId || p.id in seen) return
        remember(p.id)
        val hops = maxOf(1, START_TTL + 1 - p.ttl)
        when (p.t) {
            "ann" -> {
                val pk = runCatching { unb64.decode(p.pk ?: return) }.getOrNull() ?: return
                if (pk.size != 32) return
                val direct = peers[p.src]?.direct ?: false
                peers[p.src] = PeerInfo(p.n ?: "?", pk, if (direct) 1 else hops, now(), direct)
                emitPeers()
                forward(p, from)
            }
            "msg" -> if (p.dst == myId) {
                val info = peers[p.src] ?: return
                val ct = runCatching { unb64.decode(p.ct ?: return) }.getOrNull() ?: return
                val text = runCatching { crypto.open(ct, info.pk, myId, p.src, p.id) }.getOrNull() ?: return
                onText?.invoke(p.src, p.n ?: info.name, text, hops, p.id)
                val ack = Packet("ack", UUID.randomUUID().toString(), myId, p.src, START_TTL, now(), ref = p.id)
                remember(ack.id)
                route(ack, null) { }
            } else forward(p, from)
            "pub" -> { p.tx?.let { onPublic?.invoke(p.src, p.n ?: "?", it, p.id) }; forward(p, from) }
            "ack" -> if (p.dst == myId && p.ref != null) onDelivered?.invoke(p.ref) else forward(p, from)
        }
    }

    // ---- internals

    private fun forward(p: Packet, from: String?) {
        if (p.ttl <= 1) return
        route(p.withTtl(p.ttl - 1), from, null)
    }

    /** Sends straight to the destination if it is a neighbour, otherwise floods to all other neighbours. */
    private fun route(p: Packet, except: String?, completion: ((SendOutcome) -> Unit)?) {
        var targets = links.keys.filter { it != except }
        p.dst?.let { dst -> links.entries.firstOrNull { it.value == dst }?.let { targets = listOf(it.key) } }
        if (targets.isEmpty()) { completion?.invoke(SendOutcome.Unreachable); return }
        val data = p.toBytes()
        var pending = targets.size; var ok = false
        for (l in targets) {
            transmit?.invoke(l, data) { success ->
                if (success) ok = true
                pending--
                if (pending == 0) completion?.invoke(if (ok) SendOutcome.Sent else SendOutcome.Failed)
            } ?: run { pending--; if (pending == 0) completion?.invoke(SendOutcome.Failed) }
        }
    }

    private fun emitPeers() {
        onPeers?.invoke(peers.map { (id, i) ->
            val r = if (i.direct) (rssi[id] ?: -80) else -70 - 8 * i.hops
            Peer(id, i.name, i.hops, r.coerceIn(-95, -40), false, MeshCrypto.fingerprint(i.pk))
        }.sortedBy { it.id })
    }

    private fun remember(id: String) {
        seen.add(id); seenOrder.addLast(id)
        if (seenOrder.size > 1500) seen.remove(seenOrder.removeFirst())
    }
}
