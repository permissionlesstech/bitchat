package app.nearsend.chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Android has no Bluetooth state restoration like iOS; the equivalent is to bring the foreground service back by itself
 * after a reboot or an app update (the service is also START_STICKY, so the system restarts it after killing the process).
 * Only runs if the person finished onboarding, left "Keep running in the background" on, and Bluetooth is allowed.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val restart = ChatStore.get(ctx).shouldRunInBackground()
        Log.i("Nearsend", "BootReceiver ${intent.action}: restart=$restart")
        if (restart) MeshService.start(ctx)
    }
}
