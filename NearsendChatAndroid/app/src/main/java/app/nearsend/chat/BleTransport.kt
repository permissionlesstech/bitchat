package app.nearsend.chat

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.UUID

/**
 * Real Bluetooth LE link between nearby phones, wire-compatible with the iOS app:
 * same service/characteristic UUIDs, identity = {"id","name"}, message = {"from","name","text"}.
 * Every phone advertises the service (GATT server) and scans for it (GATT client). NOT encrypted yet.
 */
@SuppressLint("MissingPermission")
class BleTransport(private val ctx: Context, private val id: String, private var name: String) {
    companion object {
        val SERVICE: UUID = UUID.fromString("7A3C5E10-9D2B-4F6A-8C1E-4E4541525345")
        val ID_CHAR: UUID = UUID.fromString("7A3C5E11-9D2B-4F6A-8C1E-4E4541525345")
        val MSG_CHAR: UUID = UUID.fromString("7A3C5E12-9D2B-4F6A-8C1E-4E4541525345")
    }

    var onPeers: ((List<Peer>) -> Unit)? = null
    var onMessage: ((fromId: String, name: String, text: String) -> Unit)? = null
    var onState: ((String) -> Unit)? = null

    private class Link(val gatt: BluetoothGatt) {
        var msgChar: BluetoothGattCharacteristic? = null
        var peerId: String? = null
        var name = ""
        var rssi = -80
        var busy = false
        val writes = ArrayDeque<(Boolean) -> Unit>()
    }

    private val main = Handler(Looper.getMainLooper())
    private val btManager = ctx.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var running = false
    private val links = HashMap<String, Link>()          // key: device address (main thread only)
    private val pendingWrites = HashMap<String, ByteArrayOutputStream>()

    private val rssiTick = object : Runnable {
        override fun run() {
            links.values.forEach { if (!it.busy && it.peerId != null) it.gatt.readRemoteRssi() }
            if (running) main.postDelayed(this, 2000)
        }
    }

    fun start() {
        val adapter = btManager?.adapter
        if (adapter == null) { onState?.invoke("unsupported"); return }
        if (!adapter.isEnabled) { onState?.invoke("off"); return }
        if (running) return
        running = true
        server = btManager.openGattServer(ctx, serverCb)
        val svc = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(BluetoothGattCharacteristic(ID_CHAR, BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
        svc.addCharacteristic(BluetoothGattCharacteristic(MSG_CHAR, BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
        server?.addService(svc)   // advertising starts in onServiceAdded
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build()
        adapter.bluetoothLeScanner?.startScan(listOf(filter), settings, scanCb)
        main.postDelayed(rssiTick, 2000)
        onState?.invoke("ready")
    }

    fun stop() {
        running = false
        main.removeCallbacks(rssiTick)
        val adapter = btManager?.adapter
        runCatching { adapter?.bluetoothLeScanner?.stopScan(scanCb) }
        runCatching { adapter?.bluetoothLeAdvertiser?.stopAdvertising(advCb) }
        links.values.forEach { l -> l.writes.forEach { it(false) }; runCatching { l.gatt.close() } }
        links.clear()
        runCatching { server?.close() }
        server = null
        onPeers?.invoke(emptyList())
    }

    fun setName(n: String) { name = n }   // identity is read on demand, so nothing to rebuild

    /** Calls completion(true) once the other phone has acknowledged the write. */
    fun send(text: String, peerId: String, completion: (Boolean) -> Unit) {
        val link = links.values.firstOrNull { it.peerId == peerId && it.msgChar != null && !it.busy }
        val ch = link?.msgChar
        if (link == null || ch == null) { completion(false); return }
        val bytes = JSONObject().put("from", id).put("name", name).put("text", text.take(300)).toString().toByteArray()
        link.busy = true
        link.writes.addLast(completion)
        val ok = if (Build.VERSION.SDK_INT >= 33) {
            link.gatt.writeCharacteristic(ch, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION") run {
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                ch.value = bytes
                link.gatt.writeCharacteristic(ch)
            }
        }
        if (!ok) { link.busy = false; link.writes.removeLastOrNull(); completion(false) }
    }

    private fun identityBytes() = JSONObject().put("id", id).put("name", name).toString().toByteArray()

    private fun emitPeers() {
        onPeers?.invoke(links.values.mapNotNull { l ->
            l.peerId?.let { Peer(it, l.name, 1, l.rssi) }
        })
    }

    private fun handlePayload(bytes: ByteArray) {
        val o = runCatching { JSONObject(String(bytes)) }.getOrNull() ?: return
        val from = o.optString("from"); val n = o.optString("name"); val t = o.optString("text")
        if (from.isNotEmpty()) main.post { onMessage?.invoke(from, n, t) }
    }

    private fun handleIdentity(gatt: BluetoothGatt, bytes: ByteArray?) {
        val link = links[gatt.device.address] ?: return
        link.busy = false
        val o = runCatching { JSONObject(String(bytes ?: return)) }.getOrNull() ?: return
        val pid = o.optString("id")
        if (pid.isEmpty() || pid == id) return
        // Same phone seen under a new address: drop the stale link.
        links.entries.filter { it.value !== link && it.value.peerId == pid }.forEach { e ->
            links.remove(e.key); runCatching { e.value.gatt.close() }
        }
        link.peerId = pid
        link.name = o.optString("name")
        emitPeers()
        gatt.readRemoteRssi()
    }

    private fun drop(gatt: BluetoothGatt) {
        val link = links.remove(gatt.device.address)
        link?.writes?.forEach { it(false) }
        runCatching { gatt.close() }
        emitPeers()
    }

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post {
                if (!running) return@post
                val addr = result.device.address
                if (links.containsKey(addr)) return@post
                val g = result.device.connectGatt(ctx, false, gattCb, BluetoothDevice.TRANSPORT_LE)
                links[addr] = Link(g).also { if (result.rssi != 127) it.rssi = result.rssi }
            }
        }
    }

    private val advCb = object : AdvertiseCallback() {}

    private val gattCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                    if (!gatt.requestMtu(247)) gatt.discoverServices()
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) {
                    drop(gatt)
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            main.post { gatt.discoverServices() }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            main.post {
                val link = links[gatt.device.address] ?: return@post
                val svc = gatt.getService(SERVICE) ?: return@post
                link.msgChar = svc.getCharacteristic(MSG_CHAR)
                val idc = svc.getCharacteristic(ID_CHAR) ?: return@post
                link.busy = true
                gatt.readCharacteristic(idc)
            }
        }

        @Deprecated("Used on API < 33")
        override fun onCharacteristicRead(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            if (Build.VERSION.SDK_INT < 33 && ch.uuid == ID_CHAR) {
                @Suppress("DEPRECATION") val v = ch.value
                main.post { handleIdentity(gatt, v) }
            }
        }

        override fun onCharacteristicRead(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            if (ch.uuid == ID_CHAR) main.post { handleIdentity(gatt, value) }
        }

        override fun onReadRemoteRssi(gatt: BluetoothGatt, rssi: Int, status: Int) {
            main.post {
                val link = links[gatt.device.address] ?: return@post
                if (status == BluetoothGatt.GATT_SUCCESS) { link.rssi = rssi; emitPeers() }
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            main.post {
                val link = links[gatt.device.address] ?: return@post
                link.busy = false
                link.writes.removeFirstOrNull()?.invoke(status == BluetoothGatt.GATT_SUCCESS)
            }
        }
    }

    private val serverCb = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true).build()
            val data = AdvertiseData.Builder().setIncludeDeviceName(false).addServiceUuid(ParcelUuid(SERVICE)).build()
            btManager?.adapter?.bluetoothLeAdvertiser?.startAdvertising(settings, data, advCb)
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) {
            val data = identityBytes()
            val slice = if (offset <= data.size) data.copyOfRange(offset, data.size) else ByteArray(0)
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, slice)
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?,
        ) {
            if (characteristic.uuid == MSG_CHAR && value != null) {
                if (preparedWrite) pendingWrites.getOrPut(device.address) { ByteArrayOutputStream() }.write(value)
                else handlePayload(value)
            }
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val buf = pendingWrites.remove(device.address)
            if (execute && buf != null) handlePayload(buf.toByteArray())
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }
    }
}
