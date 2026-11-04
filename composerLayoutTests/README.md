# Composer layout and interaction regression tests

The Build & Test workflow runs these checks automatically in its existing jobs:

- The iOS simulator job runs 27 XCUITest cases after the standard app tests,
  using a fresh disposable simulator of the selected type/runtime and the resolved Xcode package cache. Eleven cases cover
  attachment/send and attachment/microphone bounds, ordinary/accessibility XXXL
  text, both themes, 280/390-point rows, attachment bindings, sending, synthetic
  recording/cancel and narrow text entry. Four additional cases use the actual
  production photo picker in both themes at ordinary/accessibility XXXL text. Twelve
  selected-language cases add Arabic/Hebrew/German layout coverage described below.
- The native app matrix job runs four macOS button cases serially after coverage
  and performance checks, copying resolved dependencies into a separate composer build directory. They send native
  in-process mouse events to the fully mounted composer, checking attachment,
  sending, disabled empty send and restored nonempty send. Both themes are
  exercised at width 280/ordinary and width 390/accessibility environment settings.
  This does not establish that macOS visually scales for that environment value.

The iOS runner builds the declared `ComposerLayoutHost` target and shared
`Composer Layout` scheme directly. The target shares production sources but
excludes production startup; fixture code and existing in-memory identity,
keychain and transport mocks have explicit target membership. It has no share
extension dependency.

The macOS runner selects the explicit `COMPOSER_TEST_HOST=1` SwiftPM configuration.
That configuration uses the inert entry point and includes composer support in
the existing app test target; the runner selects its four composer cases. Frame readers are declared behind `COMPOSER_TEST_HOST && os(macOS)`;
normal builds exclude their implementation and calls. The readers do not receive
hit tests and report layout allocations, not accessibility bounds.

Normal runs do not copy or rewrite source/project files. The macOS runner copies
resolved package inputs, not ordinary build products, into its own configuration
directory. It runs after coverage reporting and benchmarks. Only the optional original-composer control uses a disposable source
copy to substitute the requested baseline file.

## iOS local command

Requires macOS, Python 3, Xcode, an installed iOS test simulator and an already
resolved package cache matching `Package.resolved`. Record inputs without building:

```sh
python3 composerLayoutTests/run.py --output /tmp/composer-layout
```

Build and run all 27 cases:

```sh
python3 composerLayoutTests/run.py --output /tmp/composer-layout-run \
  --simulator "$SIMULATOR_UUID" --packages "$PACKAGE_CACHE"
```

For a focused subset, repeat `--test METHOD`; omission runs the complete suite.
Unknown or duplicate method names are rejected.

The supplied simulator is a template: the runner reads its type/runtime, creates
a new device, builds before boot, and shuts down/deletes its own device on exit.
It imports one generated 96×64 four-color PNG for photo-picker cases. A fresh
device is not assumed to have an empty photo library: the newest matching photo
is selected, and the returned image must match the generated pattern. The real picker runs only in the four cases that set
`ACTUAL_PICKER=1`; the original camera/library-binding cases stay inert. The picker
cases close the system's informational banner if present, tap the measured photo
thumbnail, and check cancellation, returned image dimensions and decoded quadrant colors, draft preservation
and a subsequent send callback. They do not request or grant PhotoKit access,
answer permission alerts, or validate the full-library authorization workflow.

The declared simulator host compiles the required test-only no-network guard
from `NetworkIsolation.c` directly into its executable. Failed installation or
IP-denial checks terminate the host before app startup. This guards the app process, not Photos/system daemons.
The guard uses the internal simulator sandbox interface `__sandbox_ms` and fails
closed if it is unavailable. Exit 90 with `reason=interface-unavailable` means the
interface could not be resolved; `reason=installation-rejected` means applying
the restriction failed. Exit 91 reports the IPv4/IPv6 and TCP/UDP check that did
not observe denial. Check the host's diagnostic output and Xcode/runtime version;
do not disable the guard to make a run pass.
Recording inputs without running does not build the guard. No guard is added to production.

## macOS local command

First resolve the repository's standard SwiftPM dependencies so the supplied
scratch directory contains the matching package inputs. Then run:

```sh
python3 composerLayoutTests/run-macos.py --output /tmp/composer-macos \
  --scratch-path "$PWD/.build"
```

An existing external dependency cache also works; its ordinary build products are not changed. `--prepare-only` records the declared inputs without requiring a cache or
building. Runtime/build process
trees deny network access and real keychain services, with isolated writable
home/cache locations. The four tests run serially with a 120-second watchdog after
a separate build capped at 600 seconds. No real file dialog, external desktop
input injection or Accessibility permission is requested.

## Results, deadlines and limits

Use a fresh output folder each time. Both runners retain input hashes, commands,
raw logs, exit codes and post-run hashes; failure log tails are printed; iOS also retains an xcresult bundle.
They reject missing/skipped cases, failed commands and input drift. Setup failures,
timeouts and interruptions produce failure records and clean up owned processes.
The workflow also runs Python runner/negative-control tests, target-membership
checks and shipping Release source/binary exclusions. The iOS runner verifies
the required guard symbol and markers before launch; host startup requires the
guard's verified status. Builds use
two jobs. iOS cases have 60-second execution limits; the xcodebuild build has
a 600-second deadline and the test command a 900-second default deadline, with separate bounded guard/media preparation.
A successful build or zero-case test command is not a passing suite.

For an iOS baseline control, export the uncorrected composer to a separate file:

```sh
python3 composerLayoutTests/run.py --output /tmp/composer-baseline \
  --simulator "$SIMULATOR_UUID" --packages "$PACKAGE_CACHE" \
  --composer /tmp/original-composer.swift --test testAccessibilityXXXL
```

The intended failure is `Attachment and send controls must not overlap`.
A setup failure, timeout or different assertion is not regression sensitivity.
Fixtures retain model wiring and an app-process network guard. The composer
and its command suggestions use three feature models: conversation UI, private
conversation and location channels. The fixture constructs only those models.
Their underlying chat model uses these dependencies before setup:

| Dependency | Why the fixture supplies it |
| --- | --- |
| Nostr transport | Inert connectivity; unexpected sends and scheduling fail |
| Deduplication factory | In-memory state instead of the persistent event store |
| Relay manager | Avoid acquiring the live shared relay manager |
| Favorites | Use the mock keychain |
| Preferences | Isolate mutable settings from normal app preferences |
| Geographic coordinator/foreground state | Retain coordinator wiring without live Tor/location dependencies |

The fixture asserts that injected services were constructed and transport/router
wiring remains connected. Production defaults remain unchanged. Geometry checks
read fresh bounds per assertion group, including after UI transitions; they do
not reuse measurements across states.
The fake recording backend is installed before the first gesture. iOS assertions
check the received Dynamic Type environment and control containment as well as
non-overlap. Camera long-press checks use one second; half-second arbitration is not covered.
Ordinary accessibility dimensions must be positive and at most 37 points (36 plus
rounding), but may describe the icon rather than its full layout allocation.

These are synthetic fixture tests using production controls/picker delegates and
fixture callbacks. They do not verify real message/media delivery, image-processing
pipelines, physical input/devices, VoiceOver, actual microphone/camera capture,
macOS file-dialog behavior or minimum-OS runtime behavior. macOS tests exercise
layout-frame geometry; the iOS layout cases separately check accessibility bounds.

## Selected-language layout coverage

Twelve additional iOS cases cover Arabic, Hebrew and German in both themes,
at ordinary and accessibility XXXL text sizes in 280-point rows. An isolated
display-channel manager lets the fixture select localized channel placeholders
without starting relay subscriptions. They assert
the actual bundle language, SwiftUI layout direction, localized mesh/channel
placeholders, mixed-direction draft preservation, numeric editing, mirrored
control ordering, containment/non-overlap, attachment requests and send callbacks
through populated, empty/microphone and send-only states. Non-Latin keyboard
entry, translation quality and VoiceOver are not established by these fixtures.
The four actual system-photo-picker cases remain English-only.

## Adding or renaming cases

The iOS runner checks discovered XCTest methods in `ComposerLayoutUITests.swift`
against the explicit `EXPECTED` inventory in `run.py` before any build, including
focused runs. Update both the methods and inventory when deliberately adding or
renaming cases; deletion, replacement, duplication or an unlisted addition fails
instead of changing the expected coverage. The macOS runner filters
`MacButtonTests` and checks its explicit `EXPECTED` inventory in `run-macos.py`;
update that inventory when adding or renaming a macOS case. Both runners reject
missing, skipped or duplicate results. Keep the README coverage description in
sync. Focused `--test` runs are for local diagnosis; the iOS workflow omits this
option so the complete suite remains automatic.
