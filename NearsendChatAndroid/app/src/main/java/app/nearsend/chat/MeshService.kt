package app.nearsend.chat

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.bluetooth.BluetoothAdapter
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the mesh (Bluetooth scanning, advertising and relaying) running when the app is closed.
 * The mesh itself lives in [ChatStore], which belongs to the process, not to a screen; this service only keeps the process
 * alive and shows the required ongoing notification ("N people nearby" with a Stop button).
 */
@SuppressLint("MissingPermission")
class MeshService : Service() {
    companion object {
        private const val CHANNEL = "mesh_service"
        private const val NOTIF_ID = 4711
        private const val ACTION_STOP = "app.nearsend.chat.STOP_MESH"
        @Volatile var running = false

        fun start(ctx: Context) {
            if (running) return
            runCatching { ContextCompat.startForegroundService(ctx, Intent(ctx, MeshService::class.java)) }
        }
        fun stop(ctx: Context) { ctx.stopService(Intent(ctx, MeshService::class.java)) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /** Restores the mesh when Bluetooth is switched off and on again while the service is running. */
    private val btReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_ON -> ChatStore.get(ctx).onBluetoothChanged(true)
                BluetoothAdapter.STATE_OFF -> ChatStore.get(ctx).onBluetoothChanged(false)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        ContextCompat.registerReceiver(this, btReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val store = ChatStore.get(this)
        if (intent?.action == ACTION_STOP) {            // the Stop button on the notification
            store.setBackground(false)
            stopSelf()
            return START_NOT_STICKY
        }
        ensureChannel()
        try {
            val n = notification(store.peers.size)
            if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            else startForeground(NOTIF_ID, n)
        } catch (e: Exception) {                        // missing Bluetooth permission, or the OS refused a background start
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        store.peerCountListener = { count -> update(count) }
        store.startIfNeeded()
        return START_STICKY
    }

    override fun onDestroy() {
        runCatching { unregisterReceiver(btReceiver) }
        running = false
        ChatStore.get(this).peerCountListener = null
        super.onDestroy()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.bg_channel), NotificationManager.IMPORTANCE_LOW))
        }
    }

    private fun update(count: Int) {
        val nm = NotificationManagerCompat.from(this)
        if (nm.areNotificationsEnabled()) nm.notify(NOTIF_ID, notification(count))
    }

    private fun notification(count: Int): Notification {
        val open = PendingIntent.getActivity(this, 0, packageManager.getLaunchIntentForPackage(packageName)!!, PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, MeshService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val text = when (count) {
            0 -> getString(R.string.bg_notif_searching)
            1 -> getString(R.string.one_person)
            else -> getString(R.string.n_people, count)
        }
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(getString(R.string.bg_notif_title)).setContentText(text)
            .setOngoing(true).setOnlyAlertOnce(true).setContentIntent(open)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, getString(R.string.bg_stop), stop)
            .build()
    }
}
