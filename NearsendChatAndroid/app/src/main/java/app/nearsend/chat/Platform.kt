package app.nearsend.chat

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.util.Base64

/** Local notifications for messages that arrive while the app is not on screen, plus small vibrations. */
@SuppressLint("MissingPermission")
object Notifier {
    @Volatile var foreground = false
    private const val CHANNEL = "messages"

    fun notify(ctx: Context, title: String, body: String) {
        if (foreground) return
        val nm = NotificationManagerCompat.from(ctx)
        if (!nm.areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= 26) {
            ctx.getSystemService(NotificationManager::class.java)
                .createNotificationChannel(NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH))
        }
        val open = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
        val pi = android.app.PendingIntent.getActivity(ctx, 0, open, android.app.PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(ctx, CHANNEL).setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title).setContentText(body).setAutoCancel(true).setContentIntent(pi).build()
        nm.notify((System.nanoTime() and 0x7FFFFFFF).toInt(), n)
    }

    fun tap(ctx: Context, ms: Long = 30) {
        val v = ctx.getSystemService(Vibrator::class.java) ?: return
        if (v.hasVibrator()) v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
    }

    fun hasPermission(ctx: Context) = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
}

/** Keeps the device's private key in app-private storage. Wiping it gives the phone a brand-new identity. */
class KeyStore(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("nearsend", Context.MODE_PRIVATE)

    fun loadOrCreate(): MeshCrypto {
        prefs.getString("sk", null)?.let { s ->
            runCatching { return MeshCrypto(Base64.getDecoder().decode(s)) }
        }
        val c = MeshCrypto.generate()
        prefs.edit().putString("sk", Base64.getEncoder().encodeToString(c.privateKeyBytes)).apply()
        return c
    }

    fun wipe() { prefs.edit().remove("sk").apply() }
}

object SystemSettings {
    fun openAppSettings(ctx: Context) {
        ctx.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", ctx.packageName, null))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
    fun openBluetooth(ctx: Context) {
        ctx.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
