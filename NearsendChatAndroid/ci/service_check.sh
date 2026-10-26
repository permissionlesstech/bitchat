#!/bin/bash
# Verifies on the emulator that the foreground service starts, stays foreground after the app is closed, and shows its notification.
# (Emulators have no Bluetooth, so this proves the service/lifecycle wiring, not real background BLE.)
PKG=app.nearsend.chat
fail() {
  echo "SERVICE CHECK FAILED: $1"
  adb logcat -d -t 600 | grep -E "FATAL|AndroidRuntime|app.nearsend|MeshService|BootReceiver|ForegroundService|SecurityException" | tail -25
  exit 1
}
for p in BLUETOOTH_SCAN BLUETOOTH_CONNECT BLUETOOTH_ADVERTISE POST_NOTIFICATIONS; do adb shell pm grant $PKG android.permission.$p; done
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity --ez onboarded true --ez markOnboarded true
sleep 6
# Reboot / update restoration: with the app force-stopped, the boot broadcast must reach the receiver and it must decide to restart.
# (A broadcast sent from adb lacks the temporary allow-list Android gives a real boot, so the OS may refuse the foreground start
#  itself; the app handles that refusal. What this proves is the wiring: receiver registered, state persisted, decision correct.)
adb shell am force-stop $PKG
sleep 2
adb logcat -c
adb root > /dev/null 2>&1; sleep 3; adb wait-for-device    # sending BOOT_COMPLETED is reserved to the system (this emulator image allows adb root)
adb shell am broadcast -f 32 -a android.intent.action.BOOT_COMPLETED -n $PKG/.BootReceiver
sleep 6
adb logcat -d -s Nearsend:I | grep -q "BootReceiver android.intent.action.BOOT_COMPLETED: restart=true" || { adb logcat -d -s Nearsend:I; fail "boot receiver did not decide to restart the service"; }
echo "boot receiver ran and decided to restart the service"
adb logcat -c
adb shell am broadcast -f 32 -a android.intent.action.MY_PACKAGE_REPLACED -n $PKG/.BootReceiver > /dev/null
sleep 4
adb logcat -d -s Nearsend:I | grep -q "MY_PACKAGE_REPLACED: restart=true" || fail "update receiver did not decide to restart the service"
echo "update receiver ran and decided to restart the service"
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity --ez onboarded true --ez startService true
sleep 6

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
