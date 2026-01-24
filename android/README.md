# BitChat Android

Native Android port of BitChat - decentralized mesh messaging.

## Features
- Bluetooth LE mesh networking
- Nostr protocol integration
- End-to-end encryption
- No accounts required

## Build

See [BUILD_GUIDE.md](../BUILD_GUIDE.md) for detailed instructions.

```bash
./gradlew assembleDebug
```

## Install

The debug APK will be at:
```
app/build/outputs/apk/debug/app-debug.apk
```

Install with:
```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```
