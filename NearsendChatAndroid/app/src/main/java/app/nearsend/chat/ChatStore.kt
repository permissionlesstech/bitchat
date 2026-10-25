package app.nearsend.chat

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * UI-facing state. On a real phone it is driven by [BleTransport]; emulators have no Bluetooth,
 * so there it shows demo data instead.
 */
class ChatStore(app: Application) : AndroidViewModel(app) {
    private val prefs = app.getSharedPreferences("nearsend", Context.MODE_PRIVATE)

    var peers by mutableStateOf(listOf<Peer>()); private set
    var conversations by mutableStateOf(listOf<Conversation>()); private set
    var nickname by mutableStateOf(prefs.getString("nickname", null) ?: "anon-${(1000..9999).random()}")
    var meshActive by mutableStateOf(true); private set
    var bluetoothState by mutableStateOf("starting"); private set   // starting | ready | off | unauthorized | unsupported

    val simulated = isEmulator()
    private val deviceId = prefs.getString("deviceID", null)
        ?: UUID.randomUUID().toString().also { prefs.edit().putString("deviceID", it).apply() }
    private var transport: BleTransport? = null

    val relayedCount get() = peers.count { it.hops > 1 }

    init { if (simulated) { seed(); drift() } }

    private fun isEmulator() = Build.FINGERPRINT.startsWith("generic") || Build.FINGERPRINT.contains("emulator") ||
        Build.HARDWARE.contains("ranchu") || Build.HARDWARE.contains("goldfish") || Build.PRODUCT.contains("sdk")

    fun hasBlePermissions(): Boolean = blePermissions().all {
        ContextCompat.checkSelfPermission(getApplication(), it) == PackageManager.PERMISSION_GRANTED
    }

    fun blePermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 31) listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        else listOf(Manifest.permission.ACCESS_FINE_LOCATION)

    /** Safe to call repeatedly (after onboarding, after the permission prompt, on resume). */
    fun startIfNeeded() {
        if (simulated || !meshActive) return
        if (!hasBlePermissions()) { bluetoothState = "unauthorized"; return }
        if (transport == null) {
            transport = BleTransport(getApplication(), deviceId, nickname).also { t ->
                t.onPeers = { peers = it }
                t.onState = { bluetoothState = it }
                t.onMessage = { id, name, text -> receive(id, name, text) }
            }
        }
        transport?.start()
    }

    fun setMesh(on: Boolean) {
        meshActive = on
        if (simulated) return
        if (on) startIfNeeded() else { transport?.stop(); peers = emptyList() }
    }

    fun applyNickname() {
        prefs.edit().putString("nickname", nickname).apply()
        transport?.setName(nickname)
    }

    fun updateNickname(n: String) { nickname = n }

    fun ensureConversation(peer: Peer) {
        if (conversations.none { it.id == peer.id }) conversations = listOf(Conversation(peer.id, peer, emptyList())) + conversations
    }

    fun markRead(id: String) {
        conversations = conversations.map { if (it.id == id && it.unread > 0) it.copy(unread = 0) else it }
    }

    fun send(text: String, id: String) {
        val m = Message(text, System.currentTimeMillis(), true, Delivery.Sending)
        conversations = conversations.map { if (it.id == id) it.copy(messages = it.messages + m) else it }
        if (simulated) {
            viewModelScope.launch {
                delay(600); update(m.id, id, Delivery.Sent)
                delay(900); update(m.id, id, Delivery.Delivered)
            }
        } else {
            val t = transport
            if (t == null) update(m.id, id, Delivery.Failed)
            else t.send(text, id) { ok -> update(m.id, id, if (ok) Delivery.Delivered else Delivery.Failed) }
        }
    }

    private fun receive(id: String, name: String, text: String) {
        val peer = peers.firstOrNull { it.id == id } ?: Peer(id, name, 1, -70)
        ensureConversation(peer)
        val m = Message(text, System.currentTimeMillis(), false)
        conversations = conversations.map { if (it.id == id) it.copy(messages = it.messages + m, unread = it.unread + 1) else it }
    }

    private fun update(mid: String, id: String, s: Delivery) {
        conversations = conversations.map { c ->
            if (c.id == id) c.copy(messages = c.messages.map { if (it.id == mid) it.copy(state = s) else it }) else c
        }
    }

    override fun onCleared() { transport?.stop() }

    private fun seed() {
        peers = listOf(
            Peer("a", "Maja", 1, -48, true), Peer("b", "Erik", 1, -66), Peer("c", "Noor", 2, -78),
            Peer("d", "Luca", 3, -88), Peer("e", "Sofia", 2, -72, true),
        )
        val now = System.currentTimeMillis()
        conversations = listOf(
            Conversation("a", peers[0], listOf(
                Message("Are you at the north gate?", now - 900_000, false),
                Message("Yes, by the water stand", now - 840_000, true),
                Message("Coming now 👋", now - 60_000, false)), unread = 1),
            Conversation("c", peers[2], listOf(Message("Relayed through Erik, nice range", now - 7_200_000, false))),
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
