#!/bin/bash
# Verifies on the emulator that the foreground service starts, stays foreground after the app is closed, and shows its notification.
# (Emulators have no Bluetooth, so this proves the service/lifecycle wiring, not real background BLE.)
PKG=app.nearsend.chat
fail() { echo "SERVICE CHECK FAILED: $1"; exit 1; }
for p in BLUETOOTH_SCAN BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE POST_NOTIFICATIONS; do adb shell pm grant $PKG android.permission.$p; done
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity --ez onboarded true --ez startService true
sleep 8
OUT=$(adb shell dumpsys activity services $PKG/.MeshService)
echo "$OUT" | grep -q "isForeground=true" || { echo "$OUT"; fail "service is not in the foreground after start"; }
echo "service is foreground while the app is open"
adb shell input keyevent KEYCODE_BACK          # closes the activity; the process must stay alive because of the service
sleep 6
adb shell pidof $PKG > /dev/null || fail "process died after the activity was closed"
OUT=$(adb shell dumpsys activity services $PKG/.MeshService)
echo "$OUT" | grep -q "isForeground=true" || { echo "$OUT"; fail "service stopped after the activity was closed"; }
echo "service still foreground after the app was closed"
adb shell cmd statusbar expand-notifications
sleep 3
mkdir -p shots; adb exec-out screencap -p > shots/16-service-notification.png
adb shell dumpsys notification --noredact | grep -q "$PKG" || fail "no notification from the app"
echo "SERVICE CHECK PASSED"
