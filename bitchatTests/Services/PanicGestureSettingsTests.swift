import Foundation
import Testing
@testable import bitchat

/// The logo triple-tap is an emergency control with two opposite failure
/// modes: wiping when nobody meant to, and failing to wipe when someone did.
/// The preference has to land on the safe side of each — confirm-first for an
/// install nobody has configured, armed for a device that was just wiped.
struct PanicGestureSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "bitchat.tests.panicgesture.\(UUID().uuidString)")!
    }

    @Test func freshInstallAsksBeforeWiping() {
        // Preserves the behavior shipped in #1588: an unset preference must
        // not silently re-arm an instant wipe on someone who never chose one.
        #expect(PanicGestureSettings.mode(in: makeDefaults()) == .confirm)
        #expect(PanicGestureSettings.installDefault == .confirm)
    }

    @Test func theSettingRoundTrips() {
        let defaults = makeDefaults()

        for mode in PanicGestureMode.allCases {
            PanicGestureSettings.setMode(mode, in: defaults)
            #expect(PanicGestureSettings.mode(in: defaults) == mode)
        }
    }

    @Test func unrecognizedStoredValueAsksBeforeWiping() {
        let defaults = makeDefaults()

        defaults.set("disabled", forKey: PanicGestureSettings.storageKey)
        #expect(PanicGestureSettings.mode(in: defaults) == .confirm)

        defaults.set(7, forKey: PanicGestureSettings.storageKey)
        #expect(PanicGestureSettings.mode(in: defaults) == .confirm)
    }

    @Test func panicWipeLeavesTheGestureArmed() {
        let defaults = makeDefaults()
        PanicGestureSettings.setMode(.off, in: defaults)

        PanicGestureSettings.resetForPanicWipe(in: defaults)

        // Not the install default: someone who just wiped under duress is on
        // the seizure path, and the next wipe must not cost them a dialog.
        #expect(PanicGestureSettings.mode(in: defaults) == .instant)
    }

    @Test func panicWipeArmsTheGestureFromEveryStartingMode() {
        for mode in PanicGestureMode.allCases {
            let defaults = makeDefaults()
            PanicGestureSettings.setMode(mode, in: defaults)

            PanicGestureSettings.resetForPanicWipe(in: defaults)

            // The written value is a constant, so nothing about the pre-wipe
            // choice can be read back off the device afterwards.
            #expect(PanicGestureSettings.mode(in: defaults) == .instant)
        }
    }

    @Test func rawValuesAreStable() {
        // Stored preferences are matched by these strings; renaming a case
        // would strand everyone who had chosen it.
        #expect(PanicGestureMode.allCases.map(\.rawValue) == ["instant", "confirm", "off"])
    }
}
