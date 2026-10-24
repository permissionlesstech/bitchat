# Direct distribution

This is the installation and release path for users who cannot reach a store.
Use project-controlled download channels and verify what you install. A mirror's
checksum alone cannot authenticate the mirror's own files.

## Android

The [Android project's releases](https://github.com/permissionlesstech/bitchat-android/releases)
provide signed direct-install APKs. Choose `bitchat-android-arm64.apk` for an
ARM64 phone, or `bitchat-android-universal.apk` when the phone architecture is
unknown. `bitchat-android-wear.apk` is for a Wear OS watch. An `.aab` is a Play
upload bundle, not a direct-install package.

Download from that repository rather than a link supplied by a stranger. Follow
the Android project's [verification instructions](https://github.com/permissionlesstech/bitchat-android/blob/main/docs/reproducible-builds.md)
and compare the release signing certificate with the project's published pin.
After verification, open the APK on the phone and permit installation by that
installer if Android asks. Keep the same distribution's signing identity for
updates; do not uninstall an existing installation merely to bypass a signature
mismatch. Installation can require temporary connectivity; Bluetooth mesh does
not turn an internet shutdown into an online relay connection.

## iOS

The public [App Store listing](https://apps.apple.com/us/app/bitchat-mesh/id6748219622)
is the established installation route. Public source archives are not installable
IPA files. The project does not designate an alternative public TestFlight link,
PWA, or trusted mirror in this guide. A maintainer must provision and document
such a channel before users can depend on it.

If you have Xcode and the required Apple signing access, build from
[verified source](VERIFYING-A-BUILD.md). Developer installation remains subject
to Apple's provisioning and signing requirements. Downloading an arbitrary IPA
does not remove those requirements or establish its authenticity.

## macOS release preparation

`scripts/package-macos-release.py` prepares a signed, notarized `.dmg` and a
SHA-256 manifest from an already exported release app. It does not sign an
unsigned app, grant access to a Developer ID, or publish a release automatically.
Until a maintainer has completed and tested this process and published the
artifact, users should follow the existing App Store or verified-source routes.

1. Build the intended tag with full Xcode using the `bitchat (macOS)` scheme.
   Archive a **Release** macOS build; export it with **Developer ID** distribution
   using the project's registered bundle identifier and app group. Enable the
   hardened runtime and preserve the app's required entitlements and provisioning.
2. Notarize the exported app through Xcode's distribution flow and staple its
   ticket. Test the app on a clean Mac before packaging. Bluetooth behavior also
   needs physical-device testing.
3. Configure a `notarytool` keychain profile on the release machine. Select the
   intended Developer ID Application certificate's complete SHA-1 fingerprint.
   Keep signing keys and notary credentials outside the checkout and release
   directory. Use the project's trusted Team ID, not a value copied from an
   untrusted app.
4. Run the helper, substituting release values. `release-assets` must not exist:

   ```sh
   python3 scripts/package-macos-release.py exported/bitchat.app release-assets \
     X.Y.Z EXPECTED_TEAM_ID CERTIFICATE_SHA1 NOTARY_KEYCHAIN_PROFILE
   ```

   The helper checks the app's version, bundle identifier, platform, signature,
   Team ID, notarization ticket, and Gatekeeper assessment. It copies the app
   into a compressed disk image with an Applications shortcut, signs the image,
   notarizes and staples it, validates its ticket and Gatekeeper assessment,
   then computes the checksum over the final stapled bytes. A failed step leaves
   no release directory at the requested destination. Existing output is never
   overwritten.
5. Attach both `bitchat-macos-X.Y.Z.dmg` and `MACOS_SHA256SUMS` to a **draft**
   release of that exact tag. Compare the app's version and source commit with
   the release notes. Publish the expected Team ID through a separately trusted
   project channel. Do not claim a SHA-256 manifest establishes publisher identity
   or reproducibility; Developer ID signing and notarization serve different
   purposes.
6. On a clean Mac, verify the checksum, mount the image, copy the app to
   Applications, and test launch, Bluetooth permission, messaging, and updating
   from the previous distribution. Confirm the app and image pass Gatekeeper
   without bypasses. Publish only after those checks pass.

For future published macOS artifacts, users can check the downloaded bytes with
`shasum -a 256 -c MACOS_SHA256SUMS`, check the app's signature with
`codesign --verify --deep --strict bitchat.app`, and compare
`codesign --display --verbose=4 bitchat.app`'s Team ID with the independently
trusted project pin. `spctl --assess --type execute bitchat.app` checks Gatekeeper
acceptance. Do not disable Gatekeeper to get an unverified download to launch.

Apple documents [Developer ID distribution](https://developer.apple.com/developer-id/)
and the [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
A successful synthetic tooling test is not evidence that a real app is signed,
notarized, or installable; those release checks require the maintainer's build.
