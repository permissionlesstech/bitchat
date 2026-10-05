import Foundation
import Testing
@testable import bitchat

struct AlternateAppIconSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "bitchat.tests.alticon.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func primarySystemNameIsNil() {
        #expect(AlternateAppIconSettings.Icon.primary.systemName == nil)
    }

    @Test func alternateSystemNamesMatchCatalog() {
        #expect(AlternateAppIconSettings.Icon.neutral.systemName == "AppIconNeutral")
        #expect(AlternateAppIconSettings.Icon.notes.systemName == "AppIconNotes")
        #expect(AlternateAppIconSettings.Icon.quiet.systemName == "AppIconQuiet")
    }

    @Test func allCasesCoverDisguiseSet() {
        let ids = Set(AlternateAppIconSettings.Icon.allCases.map(\.id))
        #expect(ids == ["primary", "AppIconNeutral", "AppIconNotes", "AppIconQuiet"])
    }

    @Test func selectedPersistsRawValueWithoutTouchingSystem() {
        let defaults = makeDefaults()
        #expect(AlternateAppIconSettings.selected(in: defaults) == .primary)

        AlternateAppIconSettings.setSelected(.notes, in: defaults, applySystem: false)
        #expect(defaults.string(forKey: AlternateAppIconSettings.storageKey) == "AppIconNotes")
        #expect(AlternateAppIconSettings.selected(in: defaults) == .notes)

        AlternateAppIconSettings.setSelected(.primary, in: defaults, applySystem: false)
        #expect(defaults.string(forKey: AlternateAppIconSettings.storageKey) == nil)
        #expect(AlternateAppIconSettings.selected(in: defaults) == .primary)
    }

    @Test func resetClearsStoredPreference() {
        let defaults = makeDefaults()
        AlternateAppIconSettings.setSelected(.quiet, in: defaults, applySystem: false)
        defaults.removeObject(forKey: AlternateAppIconSettings.storageKey)
        #expect(AlternateAppIconSettings.selected(in: defaults) == .primary)
    }
}
