import Testing
@testable import bitchat

/// Changing the logo gesture's mode asks first whenever the change lowers
/// safety in either direction. The only change that applies without a dialog
/// is the one back to the safe middle.
struct PanicDangerZoneSectionTests {
    @Test func onlyTheSafeMiddleAppliesWithoutAsking() {
        #expect(PanicDangerZoneSection.guardedTransition(to: .confirm) == nil)
        #expect(PanicDangerZoneSection.guardedTransition(to: .instant) == .arm)
        #expect(PanicDangerZoneSection.guardedTransition(to: .off) == .disarm)
    }

    @Test func eachGuardedTransitionLandsOnItsMode() {
        // The dialog's destructive button writes `transition.mode`; if this
        // mapping drifted, confirming "make it instant" could disarm instead.
        #expect(PanicDangerZoneSection.GuardedTransition.arm.mode == .instant)
        #expect(PanicDangerZoneSection.GuardedTransition.disarm.mode == .off)
    }
}
