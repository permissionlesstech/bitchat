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
 * Bluetooth LE link layer, wire-compatible with the iOS app (same UUIDs, identity JSON {"id","name","pk"}).
 * Every phone advertises the service (GATT server) and scans for it (GATT client). It only moves bytes:
 * identities and packets go up to [MeshRouter] (see PROTOCOL.md).
 */
@SuppressLint("MissingPermission")
class BleTransport(private val ctx: Context, private val id: String, private var name: String, private val publicKey: ByteArray) {
    companion object {
        val SERVICE: UUID = UUID.fromString("7A3C5E10-9D2B-4F6A-8C1E-4E4541525345")
        val ID_CHAR: UUID = UUID.fromString("7A3C5E11-9D2B-4F6A-8C1E-4E4541525345")
        val MSG_CHAR: UUID = UUID.fromString("7A3C5E12-9D2B-4F6A-8C1E-4E4541525345")
    }

    var onNeighbor: ((link: String, id: String, name: String, pk: ByteArray) -> Unit)? = null
    var onLost: ((link: String) -> Unit)? = null
    var onPacket: ((data: ByteArray) -> Unit)? = null
    var onRssi: ((link: String, rssi: Int) -> Unit)? = null
    var onState: ((String) -> Unit)? = null

    private class Link(val gatt: BluetoothGatt) {
        var msgChar: BluetoothGattCharacteristic? = null
        var peerId: String? = null
        var busy = false
        val queue = ArrayDeque<Pair<ByteArray, (Boolean) -> Unit>>()
        var inflight: ((Boolean) -> Unit)? = null
        fun failAll() { inflight?.invoke(false); inflight = null; queue.forEach { it.second(false) }; queue.clear() }
    }

    private val main = Handler(Looper.getMainLooper())
    private val btManager = ctx.getSystemService(BluetoothManager::class.java)
    private var server: BluetoothGattServer? = null
    private var running = false
    private val links = HashMap<String, Link>()          // key: device address = link id (main thread only)
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
        links.forEach { (addr, l) -> l.failAll(); runCatching { l.gatt.close() }; if (l.peerId != null) onLost?.invoke(addr) }
        links.clear()
        runCatching { server?.close() }
        server = null
    }

    fun setName(n: String) { name = n }   // identity is read on demand, so nothing to rebuild

    /** Queues one packet for a neighbour. `done(true)` once the other phone acknowledged the write. */
    fun write(linkId: String, data: ByteArray, done: (Boolean) -> Unit) {
        val link = links[linkId]
        if (link == null || link.msgChar == null) { done(false); return }
        link.queue.addLast(data to done)
        pump(link)
    }

    /** GATT allows one operation at a time, so packets are written one after another. */
    private fun pump(link: Link) {
        val ch = link.msgChar ?: return
        if (link.busy) return
        val (data, done) = link.queue.removeFirstOrNull() ?: return
        link.busy = true
        link.inflight = done
        val ok = if (Build.VERSION.SDK_INT >= 33) {
            link.gatt.writeCharacteristic(ch, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION") run {
                ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                ch.value = data
                link.gatt.writeCharacteristic(ch)
            }
        }
        if (!ok) { link.busy = false; link.inflight = null; done(false); pump(link) }
    }

    private fun identityBytes() = JSONObject().put("id", id).put("name", name)
        .put("pk", java.util.Base64.getEncoder().encodeToString(publicKey)).toString().toByteArray()

    private fun handleIdentity(gatt: BluetoothGatt, bytes: ByteArray?) {
        val addr = gatt.device.address
        val link = links[addr] ?: return
        link.busy = false
        pump(link)
        val o = runCatching { JSONObject(String(bytes ?: return)) }.getOrNull() ?: return
        val pid = o.optString("id")
        val pk = runCatching { java.util.Base64.getDecoder().decode(o.optString("pk")) }.getOrNull() ?: return
        if (pid.isEmpty() || pid == id || pk.size != 32) return
        // Same phone seen under a new address: drop the stale link.
        links.entries.filter { it.value !== link && it.value.peerId == pid }.forEach { e ->
            links.remove(e.key); runCatching { e.value.gatt.close() }; onLost?.invoke(e.key)
        }
        link.peerId = pid
        onNeighbor?.invoke(addr, pid, o.optString("name"), pk)
        gatt.readRemoteRssi()
    }

    private fun drop(gatt: BluetoothGatt) {
        val addr = gatt.device.address
        val link = links.remove(addr)
        link?.failAll()
        runCatching { gatt.close() }
        if (link?.peerId != null) onLost?.invoke(addr)
    }

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            main.post {
                if (!running) return@post
                val addr = result.device.address
                if (links.containsKey(addr)) return@post
                val g = result.device.connectGatt(ctx, false, gattCb, BluetoothDevice.TRANSPORT_LE)
                links[addr] = Link(g)
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
                if (status == BluetoothGatt.GATT_SUCCESS && link.peerId != null) onRssi?.invoke(gatt.device.address, rssi)
            }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            main.post {
                val link = links[gatt.device.address] ?: return@post
                link.busy = false
                val cb = link.inflight; link.inflight = null
                cb?.invoke(status == BluetoothGatt.GATT_SUCCESS)
                pump(link)
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
                else main.post { onPacket?.invoke(value) }
            }
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }

        override fun onExecuteWrite(device: BluetoothDevice, requestId: Int, execute: Boolean) {
            val buf = pendingWrites.remove(device.address)
            if (execute && buf != null) { val bytes = buf.toByteArray(); main.post { onPacket?.invoke(bytes) } }
            server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }
    }
}
