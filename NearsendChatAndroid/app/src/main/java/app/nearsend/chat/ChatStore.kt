package app.nearsend.chat

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * UI-facing state. On a real phone it is driven by [BleTransport] + [MeshRouter]; emulators have no Bluetooth,
 * so there it shows demo data instead. Conversations are saved on the device.
 */
class ChatStore(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("nearsend", Context.MODE_PRIVATE)
    private val file = File(app.filesDir, "chat.json")
    private val main = Handler(Looper.getMainLooper())
    private val keys = KeyStore(app)

    var peers by mutableStateOf(listOf<Peer>()); private set
    var conversations by mutableStateOf(listOf<Conversation>()); private set
    var nickname by mutableStateOf(prefs.getString("nickname", null) ?: "anon-${(1000..9999).random()}")
    var meshActive by mutableStateOf(true); private set
    var bluetoothState by mutableStateOf("starting"); private set   // starting | ready | off | unauthorized | unsupported
    var myFingerprint by mutableStateOf("A3F1 9C02 7BD4 E58A\n11C0 4F6E 92AB 3D77"); private set
    var verified by mutableStateOf(setOf<String>()); private set
    var activeConversation: String? = null
    var wipeCount by mutableStateOf(0); private set   // UI returns to onboarding when this changes

    val simulated = isEmulator()
    private var deviceId = prefs.getString("deviceID", null) ?: newDeviceId()
    private var transport: BleTransport? = null
    private var router: MeshRouter? = null
    private val inflight = HashSet<String>()
    private val tick = object : Runnable { override fun run() { router?.tick(); main.postDelayed(this, 8000) } }

    val relayedCount get() = peers.count { it.hops > 1 }
    val unreadTotal get() = conversations.sumOf { it.unread }

    init {
        if (simulated) { seed(); drift() } else load()
        ensurePublicChannel()
    }

    private fun newDeviceId() = UUID.randomUUID().toString().also { prefs.edit().putString("deviceID", it).apply() }

    private fun isEmulator() = Build.FINGERPRINT.startsWith("generic") || Build.FINGERPRINT.contains("emulator") ||
        Build.HARDWARE.contains("ranchu") || Build.HARDWARE.contains("goldfish") || Build.PRODUCT.contains("sdk")

    // ---- lifecycle

    fun blePermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        else listOf(Manifest.permission.ACCESS_FINE_LOCATION)

    fun hasBlePermissions(): Boolean = blePermissions().all {
        ContextCompat.checkSelfPermission(getApplication(), it) == PackageManager.PERMISSION_GRANTED
    }

    /** Safe to call repeatedly (after onboarding, after the permission prompt, on resume). */
    fun startIfNeeded() {
        if (simulated || !meshActive) return
        if (!hasBlePermissions()) { bluetoothState = "unauthorized"; return }
        if (router == null) {
            val crypto = keys.loadOrCreate()
            myFingerprint = crypto.fingerprint
            val r = MeshRouter(deviceId, nickname, crypto)
            val t = BleTransport(getApplication(), deviceId, nickname, crypto.publicKey)
            r.transmit = { link, data, done -> t.write(link, data, done) }
            r.onPeers = { setPeers(it) }
            r.onText = { from, name, text, hops, id -> receiveText(from, name, text, hops, id) }
            r.onPublic = { _, name, text, id -> receivePublic(name, text, id) }
            r.onDelivered = { markDelivered(it) }
            t.onNeighbor = { link, id, name, pk -> r.neighborConnected(link, id, name, pk) }
            t.onLost = { r.neighborLost(it) }
            t.onPacket = { r.receive(it, null) }
            t.onRssi = { link, rssi -> r.updateRssi(link, rssi) }
            t.onState = { bluetoothState = it }
            router = r; transport = t
            main.postDelayed(tick, 8000)
        }
        transport?.start()
    }

    fun setMesh(on: Boolean) {
        meshActive = on
        if (simulated) return
        if (on) startIfNeeded() else { transport?.stop(); peers = emptyList() }
    }

    fun updateNickname(n: String) { nickname = n }

    fun applyNickname() {
        prefs.edit().putString("nickname", nickname).apply()
        router?.myName = nickname
        transport?.setName(nickname)
        save()
    }

    /** Panic wipe: forget every message, key and setting. The phone gets a brand-new identity. */
    fun wipeAll() {
        main.removeCallbacks(tick)
        transport?.stop(); transport = null; router = null; inflight.clear()
        keys.wipe(); file.delete()
        prefs.edit().clear().apply()
        deviceId = newDeviceId()
        verified = emptySet(); peers = emptyList(); conversations = emptyList()
        nickname = "anon-${(1000..9999).random()}"
        if (!simulated) myFingerprint = ""
        ensurePublicChannel()
        wipeCount++
        if (simulated) seed() else startIfNeeded()
    }

    // ---- conversations

    fun ensureConversation(peer: Peer) {
        if (conversations.none { it.id == peer.id }) conversations = conversations + Conversation(peer.id, peer, emptyList())
    }

    fun markRead(id: String) {
        if (conversations.any { it.id == id && it.unread > 0 }) {
            conversations = conversations.map { if (it.id == id) it.copy(unread = 0) else it }; save()
        }
    }

    fun toggleVerified(peer: Peer) {
        if (peer.fingerprint.isEmpty()) return
        verified = if (peer.fingerprint in verified) verified - peer.fingerprint else verified + peer.fingerprint
        peers = peers.map { it.copy(verified = it.fingerprint in verified) }
        save()
    }

    fun send(text: String, id: String) {
        val m = Message(text, System.currentTimeMillis(), true, Delivery.Sending)
        conversations = conversations.map { if (it.id == id) it.copy(messages = it.messages + m) else it }
        save()
        when {
            simulated -> viewModelScope.launch {
                delay(600); update(m.id, id, Delivery.Sent)
                delay(900); update(m.id, id, Delivery.Delivered)
            }
            id == PUBLIC_CHANNEL_ID -> router?.sendPublic(text, m.id) { update(m.id, id, if (it == SendOutcome.Sent) Delivery.Sent else Delivery.Failed) }
                ?: update(m.id, id, Delivery.Failed)
            else -> trySend(m, id)
        }
    }

    fun retry(messageId: String, id: String) {
        conversations = conversations.map { c ->
            if (c.id != id) c else c.copy(messages = c.messages.map {
                if (it.id == messageId) it.copy(state = Delivery.Sending, timeMs = System.currentTimeMillis()) else it
            })
        }
        flushOutbox()
    }

    private fun trySend(m: Message, id: String) {
        val r = router ?: return
        if (!inflight.add(m.id)) return
        r.sendText(m.text, id, m.id) { outcome ->
            inflight.remove(m.id)
            when (outcome) {
                SendOutcome.Sent -> update(m.id, id, Delivery.Sent)
                SendOutcome.Failed -> update(m.id, id, Delivery.Failed)
                SendOutcome.Unreachable -> {}      // stays queued until the person comes into range
            }
        }
    }

    /** Sends queued messages whose recipient is now reachable; gives up after 10 minutes. */
    private fun flushOutbox() {
        if (simulated) return
        for (c in conversations) {
            if (c.id == PUBLIC_CHANNEL_ID) continue
            for (m in c.messages) {
                if (!m.mine || m.state != Delivery.Sending) continue
                if (System.currentTimeMillis() - m.timeMs > 600_000) update(m.id, c.id, Delivery.Failed)
                else if (peers.any { it.id == c.id }) trySend(m, c.id)
            }
        }
    }

    private fun setPeers(list: List<Peer>) {
        val known = peers.map { it.id }.toSet()
        val mapped = list.map { it.copy(verified = it.fingerprint in verified) }.sortedWith(compareBy<Peer> { it.hops }.thenByDescending { it.rssi })
        if (mapped.any { it.id !in known }) Notifier.tap(getApplication(), 15)
        peers = mapped
        conversations = conversations.map { c -> mapped.firstOrNull { it.id == c.id }?.let { c.copy(peer = it) } ?: c }
        flushOutbox()
    }

    private fun receiveText(from: String, name: String, text: String, hops: Int, id: String) {
        ensureConversation(peers.firstOrNull { it.id == from } ?: Peer(from, name, hops, -80))
        if (conversations.firstOrNull { it.id == from }?.messages?.any { it.id == id } == true) return
        val m = Message(text, System.currentTimeMillis(), false, id = id, hops = hops)
        conversations = conversations.map {
            if (it.id == from) it.copy(messages = it.messages + m, unread = if (activeConversation == from) it.unread else it.unread + 1) else it
        }
        Notifier.notify(getApplication(), name, text)
        Notifier.tap(getApplication())
        save()
    }

    private fun receivePublic(name: String, text: String, id: String) {
        if (conversations.firstOrNull { it.id == PUBLIC_CHANNEL_ID }?.messages?.any { it.id == id } == true) return
        val m = Message(text, System.currentTimeMillis(), false, id = id, sender = name)
        conversations = conversations.map {
            if (it.id == PUBLIC_CHANNEL_ID) it.copy(messages = it.messages + m, unread = if (activeConversation == PUBLIC_CHANNEL_ID) it.unread else it.unread + 1) else it
        }
        Notifier.notify(getApplication(), "#nearby · $name", text)
        save()
    }

    private fun markDelivered(id: String) {
        conversations.filter { c -> c.messages.any { it.id == id } }.forEach { update(id, it.id, Delivery.Delivered) }
    }

    private fun update(mid: String, id: String, s: Delivery) {
        conversations = conversations.map { c ->
            if (c.id != id) c else c.copy(messages = c.messages.map {
                if (it.id != mid || (it.state == Delivery.Delivered && s != Delivery.Delivered)) it else it.copy(state = s)   // never downgrade
            })
        }
        save()
    }

    private fun ensurePublicChannel() {
        if (conversations.none { it.id == PUBLIC_CHANNEL_ID }) {
            conversations = listOf(Conversation(PUBLIC_CHANNEL_ID, Peer(PUBLIC_CHANNEL_ID, "Nearby", 1, -50), emptyList())) + conversations
        }
    }

    override fun onCleared() { main.removeCallbacks(tick); transport?.stop() }

    // ---- persistence

    private fun save() {
        if (simulated) return
        val o = JSONObject().put("verified", JSONArray(verified.toList()))
        o.put("conversations", JSONArray(conversations.map { c ->
            JSONObject().put("id", c.id).put("unread", c.unread)
                .put("peer", JSONObject().put("id", c.peer.id).put("name", c.peer.name).put("hops", c.peer.hops).put("rssi", c.peer.rssi).put("fp", c.peer.fingerprint))
                .put("messages", JSONArray(c.messages.map { m ->
                    JSONObject().put("id", m.id).put("text", m.text).put("t", m.timeMs).put("mine", m.mine)
                        .put("state", m.state.name).put("hops", m.hops).apply { m.sender?.let { put("sender", it) } }
                }))
        }))
        runCatching { file.writeText(o.toString()) }
    }

    private fun load() {
        runCatching {
            val o = JSONObject(file.readText())
            verified = (0 until o.getJSONArray("verified").length()).map { o.getJSONArray("verified").getString(it) }.toSet()
            val cs = o.getJSONArray("conversations")
            conversations = (0 until cs.length()).map { i ->
                val c = cs.getJSONObject(i); val p = c.getJSONObject("peer"); val ms = c.getJSONArray("messages")
                Conversation(c.getString("id"), Peer(p.getString("id"), p.getString("name"), p.getInt("hops"), p.getInt("rssi"), false, p.optString("fp")),
                    (0 until ms.length()).map { j ->
                        val m = ms.getJSONObject(j)
                        Message(m.getString("text"), m.getLong("t"), m.getBoolean("mine"), Delivery.valueOf(m.getString("state")),
                            m.getString("id"), m.getInt("hops"), if (m.has("sender")) m.getString("sender") else null)
                    }, c.getInt("unread"))
            }
        }
        // Messages still marked "sending" stay queued; they are retried when the person is next in range.
    }

    // ---- demo data (emulator)

    private fun seed() {
        peers = listOf(
            Peer("a", "Maja", 1, -48, true, "DEMO"), Peer("b", "Erik", 1, -66), Peer("c", "Noor", 2, -78),
            Peer("d", "Luca", 3, -88), Peer("e", "Sofia", 2, -72, true),
        )
        val now = System.currentTimeMillis()
        conversations = listOf(
            Conversation(PUBLIC_CHANNEL_ID, Peer(PUBLIC_CHANNEL_ID, "Nearby", 1, -50), listOf(
                Message("Anyone near the main stage?", now - 300_000, false, sender = "Luca"),
                Message("Yes, by the left speaker", now - 240_000, true, Delivery.Sent))),
            Conversation("a", peers[0], listOf(
                Message("Are you at the north gate?", now - 900_000, false),
                Message("Yes, by the water stand", now - 840_000, true),
                Message("Coming now 👋", now - 60_000, false)), unread = 1),
            Conversation("c", peers[2], listOf(Message("Relayed through Erik, nice range", now - 7_200_000, false, hops = 2))),
        )
    }

    private fun drift() {
        viewModelScope.launch {
            while (true) {
                delay(2500)
                peers = peers.map { it.copy(rssi = (it.rssi + (-3..3).random()).coerceIn(-95, -40)) }
            }
        }
    }
}
