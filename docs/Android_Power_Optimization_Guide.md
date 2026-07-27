# BitChat Android BLE Power Optimization & Doze Mode Guide

This guide provides concrete solutions for battery management, Android 16 Doze mode restrictions (**#124**), and aggressive OEM task kills (**#214 / #256**).

---

## 1. Resolving Android 16 Doze Mode Connection Issues (#124)

### Problem
On Android 16 and modern API levels, system Doze mode suspends background BLE scanning and network sockets even when "Battery Optimization" is turned off for standard background services.

### Solution: Foreground Service with Low-Priority Persistent Notification
1. **Promote `BleService` to a Foreground Service**:
   ```kotlin
   class BleService : Service() {
       override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
           val notification = NotificationCompat.Builder(this, CHANNEL_ID)
               .setContentTitle("BitChat Mesh Active")
               .setContentText("Maintaining local BLE mesh connectivity")
               .setSmallIcon(R.drawable.ic_mesh_active)
               .setPriority(NotificationCompat.PRIORITY_MIN) // Minimal visual disruption
               .setCategory(NotificationCompat.CATEGORY_SERVICE)
               .setOngoing(true)
               .build()

           startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
           return START_STICKY
       }
   }
   ```

2. **Acquire Partial WakeLock during active BLE transfer bursts**:
   Release the WakeLock immediately when idle to allow the CPU to sleep while the BLE radio operates in hardware duty-cycled scan mode.

---

## 2. Preventing OEM App Kills on Honor / Huawei / Xiaomi (#214 / #256)

### Problem
Certain OEM Android skins (EMUI, MagicUI, MIUI) use aggressive battery daemons (`PowerGenie`, `HwPowerManager`) that ignore standard Android battery settings and kill background processes.

### Solution
1. **Detect OEM Skin & Prompt User Proactively**:
   ```kotlin
   fun promptOemBatteryExemption(context: Context) {
       val manufacturer = Build.MANUFACTURER.lowercase()
       if (manufacturer.contains("huawei") || manufacturer.contains("honor") || manufacturer.contains("xiaomi")) {
           val intent = Intent().apply {
               component = ComponentName(
                   "com.huawei.systemmanager",
                   "com.huawei.systemmanager.optimize.process.ProtectActivity"
               )
           }
           if (context.packageManager.resolveActivity(intent, 0) != null) {
               context.startActivity(intent)
           }
       }
   }
   ```

2. **Request `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`**:
   Ensure `android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is requested so system Doze exemption is active for BLE advertisement scanning.
