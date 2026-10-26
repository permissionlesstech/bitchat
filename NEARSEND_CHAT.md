# Nearsend Chat

Offline, nearby chat for iPhone and Android over Bluetooth LE. No internet, no account, no phone number.
Belongs to the [nearsend.app](https://nearsend.app) family and shares its "Open Sky" design.

> **Status: early development.** Everything below is implemented and compiles, and the crypto + relay logic is unit-tested in CI
> (iOS 21 checks, Android 9 tests, including a message encrypted by Python that both apps decrypt).
> **Nothing has been tested on physical phones yet**, so real Bluetooth behaviour is unproven. Not security audited
> (see `docs/nearsend-chat/PROTOCOL.md`, section 5). Not compatible with the Bitchat protocol. This repository is a fork of
> Bitchat (GPL-3.0), so this work is GPL-3.0 too.

## Features (both apps)

- Bluetooth discovery between phones, animated radar with signal strength.
- **End-to-end encrypted direct messages** (X25519 + HKDF + ChaCha20-Poly1305), real **fingerprints**, "mark as verified".
- **Multi-hop relay** (up to 5 hops), delivery receipts, **public "Nearby channel"** (unencrypted, clearly labelled).
- Messages are **saved on the phone**; messages to people out of range are **queued and sent when they appear**; failed messages can be retried.
- Local **notifications** and haptics; on Android a **foreground service** keeps Bluetooth running when the app is closed (switchable in the You tab). **Erase everything** (button or triple-tap the title) wipes messages, keys and identity.
- **12 languages** that follow the phone's language, plus an in-app language picker (You tab): English, Svenska, Español, Français, Deutsch, Português, Italiano, العربية (right-to-left), Türkçe, Русский, 简体中文, 日本語.
- Light/dark "Open Sky" design from nearsend.app, app icons, Reduce Motion and screen-reader labels.

Docs: [`PROTOCOL.md`](docs/nearsend-chat/PROTOCOL.md) · [`PRIVACY.md`](docs/nearsend-chat/PRIVACY.md) (draft) · [`RELEASING.md`](docs/nearsend-chat/RELEASING.md)

## What's in this repo

| Path | What |
|---|---|
| `NearsendChatiOS/` | iOS app (SwiftUI, iOS 17+, CoreBluetooth) |
| `NearsendChatAndroid/` | Android app (Kotlin, Jetpack Compose, minSdk 26, Android BLE) |
| `.github/workflows/nearsend-chat-ios.yml` | Builds iOS on a macOS runner, screenshots simulator, commits Xcode project + previews |
| `.github/workflows/nearsend-chat-android.yml` | Builds the APK, screenshots an emulator, commits Gradle wrapper + font + previews |
| `i18n/` | One translation table (`translations.txt`) → generates iOS `*.lproj` and Android `values-*` strings (`python3 i18n/generate.py`) |
| `docs/nearsend-chat/` | Protocol spec, privacy policy draft, release guide |
| `*/previews/` | CI screenshots (day, night, several languages) |

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

Every phone plays both roles at once, so no pairing step is needed: it advertises the Nearsend service (GATT server) and scans
for it (GATT client). A router on top floods announcements, public messages and encrypted direct messages with a hop limit and
de-duplication. Full details, packet format, encryption and test vectors: [`docs/nearsend-chat/PROTOCOL.md`](docs/nearsend-chat/PROTOCOL.md).

Code: `NearsendChatiOS/Sources/Mesh/` (`BLETransport`, `MeshRouter`, `MeshCrypto`) and `NearsendChatAndroid/app/src/main/java/app/nearsend/chat/`
(`BleTransport.kt`, `MeshRouter.kt`, `MeshCrypto.kt`). Both implement the same protocol and run the same relay scenarios in CI.

## Design system

Taken from the Nearsend web app's `DESIGN.md`:

- Fixed sky background: blue to peach by day, navy with stars by night.
- Frosted-glass surfaces (white 84% by day, navy 74% by night), 24 px card radius, 12 px buttons.
- One filled blue per screen: action blue `#2F6FE0` (deep `#2459C0`). Green only for "connected / secure".
- Navy ink `#1B2A4A` by day, `#EAF2FF` by night. Text sitting directly on the sky goes on a dark-blue pill.
- Anton (capitals) for headlines and page titles, the system sans for everything else.
  The font file is downloaded from Google Fonts (OFL) by CI and committed.

## Known limitations

- Untested on real hardware. Android↔iPhone interoperability is designed and unit-tested at the message level, not proven over the air.
- Not audited. No forward secrecy; announcements are unauthenticated until two people compare fingerprints; metadata is visible to relays.
- Messages are limited to 180 UTF-8 bytes; no photos or voice notes yet.
- Background operation: Android has a foreground service ("Keep running in the background", on by default) that is verified on an emulator only; real Bluetooth in the background is untested, and some phone makers kill background apps. iOS declares the Bluetooth background modes but has no state restoration yet, so iOS may suspend the app.
- Translations were written without native-speaker review.
- Demo data is shown on simulators/emulators (they have no Bluetooth).

## Next steps

1. Test on real phones (see `RELEASING.md` section 0) and fix what breaks.
2. Test the Android foreground service on real phones (including battery-saver behaviour); add iOS state restoration.
3. Independent security review; signatures for announcements and public messages; forward secrecy.
4. Store-and-forward for people who are away, group chats, small images.
5. Native-speaker review of the translations; TestFlight / Play internal testing.
6. Decide on Bitchat protocol compatibility (currently none).

## Credits and licence

Fork of [Bitchat](https://github.com/permissionlesstech/bitchat) (GPL-3.0). Design from nearsend.app.
Anton font by Vernon Adams, SIL Open Font License.
