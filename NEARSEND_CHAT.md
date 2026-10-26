# Nearsend Chat

Offline, nearby chat for iPhone and Android over Bluetooth LE. No internet, no account, no phone number.
Belongs to the [nearsend.app](https://nearsend.app) family and shares its "Open Sky" design.

> **Status: early development.** Real Bluetooth discovery and plain-text messaging are implemented but
> have **not been tested on physical devices yet**. Messages are **not encrypted**. Not security audited.
> Not compatible with the Bitchat protocol. This repository is a fork of Bitchat (GPL-3.0), so this work is GPL-3.0 too.

## What's in this repo

| Path | What |
|---|---|
| `NearsendChatiOS/` | iOS app (SwiftUI, iOS 17+, CoreBluetooth) |
| `NearsendChatAndroid/` | Android app (Kotlin, Jetpack Compose, minSdk 26, Android BLE) |
| `.github/workflows/nearsend-chat-ios.yml` | Builds iOS on a macOS runner, screenshots simulator, commits Xcode project + previews |
| `.github/workflows/nearsend-chat-android.yml` | Builds the APK, screenshots an emulator, commits Gradle wrapper + font + previews |
| `*/previews/` | CI screenshots (day and night) |

The rest of the repository is the unmodified upstream Bitchat iOS app.
Work lives on the `ios-app` branch.

## Screens (same on both platforms)

Onboarding → **Nearby** (animated radar + peer list) → **Chats** → **Thread** → **You** (nickname, fingerprint placeholder, status).
Light ("day sky") and dark ("night sky") themes follow the device setting.

## Run it

**iOS** (Xcode 15+, macOS)
```
git clone -b ios-app https://github.com/zakariakaab-hash/bitchat
cd bitchat/NearsendChatiOS
./run-on-mac.sh            # builds, launches in an iPhone simulator, opens Xcode
```
Or open `NearsendChatiOS/NearsendChat.xcodeproj` and press Run. For a real iPhone choose your Apple ID under
Signing & Capabilities. The project is regenerated from `project.yml` with XcodeGen (`xcodegen generate`).

**Android** (Android Studio, JDK 17)
Open the `NearsendChatAndroid` folder in Android Studio, let Gradle sync, run on a phone with USB debugging
(or `./gradlew :app:assembleDebug`). Allow the Bluetooth permission prompt shown after onboarding.

**Simulators and emulators have no Bluetooth.** They show clearly labelled demo data.
Real discovery needs two physical devices (two iPhones, two Androids, or one of each).

## How the Bluetooth link works

Every phone plays both roles at once, so no pairing step is needed:

- **Peripheral / GATT server:** advertises the Nearsend service and serves two characteristics.
- **Central / GATT client:** scans for the service, connects, reads the peer's identity, polls RSSI every 2 s
  (this drives the radar distance), and writes messages.

The two apps are wire-compatible:

| Item | Value |
|---|---|
| Service UUID | `7A3C5E10-9D2B-4F6A-8C1E-4E4541525345` |
| Identity characteristic (read) | `7A3C5E11-9D2B-4F6A-8C1E-4E4541525345` → JSON `{"id": "<device uuid>", "name": "<nickname>"}` |
| Message characteristic (write, with response) | `7A3C5E12-9D2B-4F6A-8C1E-4E4541525345` → JSON `{"from": "<id>", "name": "<nickname>", "text": "<up to 300 chars>"}` |

Code: `NearsendChatiOS/Sources/Mesh/BLETransport.swift` and
`NearsendChatAndroid/app/src/main/java/app/nearsend/chat/BleTransport.kt`.
The UI talks to a small store (`ChatStore`) that wraps the transport.

## Design system

Taken from the Nearsend web app's `DESIGN.md`:

- Fixed sky background: blue to peach by day, navy with stars by night.
- Frosted-glass surfaces (white 84% by day, navy 74% by night), 24 px card radius, 12 px buttons.
- One filled blue per screen: action blue `#2F6FE0` (deep `#2459C0`). Green only for "connected / secure".
- Navy ink `#1B2A4A` by day, `#EAF2FF` by night. Text sitting directly on the sky goes on a dark-blue pill.
- Anton (capitals) for headlines and page titles, the system sans for everything else.
  The font file is downloaded from Google Fonts (OFL) by CI and committed.

## Known limitations

- Direct links only: no multi-hop relaying, no store-and-forward.
- No encryption, no identity verification (the fingerprint card is a placeholder).
- Messages limited to 300 characters; no delivery receipts beyond the write acknowledgement.
- No background operation tested on either platform.
- iOS builds are verified on a newer Xcode in CI; older Xcode (15.2) is untested. The project file format is
  lowered to be openable in Xcode 15.
- Simulator/emulator builds only show demo data; device behaviour is untested.

## Suggested next steps

1. Test two real phones (iPhone↔iPhone, Android↔Android, iPhone↔Android) and fix what breaks.
2. Add end-to-end encryption (e.g. Noise) and real key fingerprints.
3. Multi-hop relay and store-and-forward.
4. Background Bluetooth, notifications.
5. Decide on Bitchat protocol compatibility (currently none).

## Credits and licence

Fork of [Bitchat](https://github.com/permissionlesstech/bitchat) (GPL-3.0). Design from nearsend.app.
Anton font by Vernon Adams, SIL Open Font License.
