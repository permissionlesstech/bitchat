# Releasing Nearsend Chat

What is still needed before real people can install the apps. Items marked **(you)** need your accounts or decisions.

## 0. Before any release
- [ ] **Test on real phones:** iPhone↔iPhone, Android↔Android, iPhone↔Android, and a 3-phone chain for relaying. Nothing has run on hardware yet.
- [ ] Decide the Bitchat question: this app is **not** compatible with Bitchat. The repo is a GPL-3.0 fork, so releases must offer source (the repo does).
- [ ] Get the protocol reviewed (`PROTOCOL.md` section 5). Do not market it for protests, emergencies or anything safety-critical until then.
- [ ] Publish `PRIVACY.md` at a URL (e.g. nearsend.app/chat/privacy) and fill in the contact details. **(you)**

## 1. iOS — TestFlight, then App Store
1. Apple Developer Program, about **US$99 / year**. **(you)**
2. In Xcode open `NearsendChatiOS/NearsendChat.xcodeproj` → Signing & Capabilities → pick your team. Keep the bundle id `app.nearsend.chat` or change it in `project.yml` and re-run `xcodegen generate`.
3. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`.
4. Product → Archive → Distribute App → App Store Connect → Upload. Add testers in TestFlight.
5. App Store listing: name, subtitle, description, privacy policy URL, age rating, screenshots (see `NearsendChatiOS/previews/`; App Store needs 6.9″/6.5″ sizes — re-shoot from the matching simulators).
6. **App Review notes:** explain that the app needs two physical devices to demonstrate Bluetooth, and why it declares the `bluetooth-central` and `bluetooth-peripheral` background modes (receive messages while the screen is off). Provide a short demo video. State restoration (`bluetooth-central`/`bluetooth-peripheral` plus restore identifiers) is the reason for the background modes. Reviewers cannot test Bluetooth alone — expect questions.
7. Privacy "nutrition label": *Data not collected*.

## 2. Android — internal testing, then Play
1. Google Play Console, one-time **US$25**. **(you)**
2. Create an upload key and keep it safe: `keytool -genkey -v -keystore nearsend-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload`. **Never commit it.**
3. Add a `signingConfigs` block (reading passwords from `~/.gradle/gradle.properties`) and run `./gradlew :app:bundleRelease`. Upload the `.aab` to *Internal testing*.
4. Store listing, privacy policy URL, Data safety form: *no data collected or shared*, content rating, target audience.
5. Bluetooth permissions are declared `neverForLocation`, so no location prompt on Android 12+.
6. Background delivery: `MeshService` is a foreground service of type `connectedDevice` (permissions `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_CONNECTED_DEVICE`). Play asks you to declare foreground service types in the Console: choose *Connected device* and explain it is for Bluetooth messaging with nearby phones while the app is closed. It shows an ongoing notification and can be switched off in the You tab. `RECEIVE_BOOT_COMPLETED` is declared so the service comes back after a reboot or update (Play accepts this for apps whose core feature needs it; mention it in the listing). Some phone makers (Xiaomi, Huawei, OnePlus, Samsung "sleeping apps") kill background apps anyway; tell testers to exclude the app from battery optimisation (see dontkillmyapp.com).

## 3. Adding or fixing a language
Edit `i18n/translations.txt` (one row per string, one column per language), then run `python3 i18n/generate.py`.
This regenerates the iOS `*.lproj/Localizable.strings` and the Android `values-*/strings.xml` so the two apps stay in sync.
To add a language, add a column and the code to `LANGS` in `generate.py` and to the picker lists (`AppLanguage.all` in `NearsendChatApp.swift`, `LANGUAGES` in `Screens.kt`).
The current translations were produced without a native-speaker review: have each reviewed before release.

## 4. Continuous integration
`.github/workflows/nearsend-chat-ios.yml` and `...-android.yml` run the protocol tests, build both apps and refresh the screenshots on every push to `ios-app`.

## 5. Testing iOS background behaviour (needs two iPhones)
1. Run on both phones from Xcode, finish onboarding, confirm they see each other, then press Home on phone A (do **not** force-quit).
2. Send a message from phone B: phone A should show a notification within a few seconds, even with the screen locked.
3. Restoration: in Xcode, Debug ▸ *Simulate memory warning* does not terminate the app, so use Xcode's *Product ▸ Stop*, then **re-launch from a message**: with phone A stopped from Xcode (not swiped away in the app switcher), send a message from phone B; iOS should relaunch A in the background and deliver a notification. If it does not, check Settings ▸ General ▸ Background App Refresh is on.
4. Remember: iOS never restores an app the user force-quit, and may delay background work in Low Power Mode.

## 6. Testing Android restart after reboot (needs a real phone)
CI proves the boot/update receiver runs and decides to restart the service, but an `adb` broadcast does not carry the temporary
allow-list that Android gives a real boot, so the OS-level foreground start after a real reboot is untested.
Test: finish onboarding, leave "Keep running in the background" on, reboot the phone, and check that the "Nearsend Chat is on"
notification appears without opening the app. Also test after installing an update over the app, and after toggling Bluetooth off and on.
