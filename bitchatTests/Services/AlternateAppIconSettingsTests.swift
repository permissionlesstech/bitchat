import Foundation
import Testing
@testable import bitchat

struct AlternateAppIconSettingsTests {
    private func makeDefaults() -> (suite: String, defaults: UserDefaults) {
        let suite = "bitchat.tests.alticon.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    private func cleanup(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
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
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        #expect(AlternateAppIconSettings.storedSelection(in: defaults) == nil)

        AlternateAppIconSettings.setSelected(.notes, in: defaults, applySystem: false)
        #expect(defaults.string(forKey: AlternateAppIconSettings.storageKey) == "AppIconNotes")
        #expect(AlternateAppIconSettings.storedSelection(in: defaults) == .notes)

        AlternateAppIconSettings.setSelected(.primary, in: defaults, applySystem: false)
        #expect(defaults.string(forKey: AlternateAppIconSettings.storageKey) == nil)
        #expect(AlternateAppIconSettings.storedSelection(in: defaults) == nil)
    }

    @Test func resetClearsStoredPreferenceWithoutApplyingPrimary() {
        let (suite, defaults) = makeDefaults()
        defer { cleanup(suite) }
        AlternateAppIconSettings.setSelected(.quiet, in: defaults, applySystem: false)
        var applied: [AlternateAppIconSettings.Icon] = []
        AlternateAppIconSettings.applyStoredPreference(in: defaults) { applied.append($0) }
        #expect(applied == [.quiet])

        AlternateAppIconSettings.reset(in: defaults)
        AlternateAppIconSettings.applyStoredPreference(in: defaults) { applied.append($0) }
        #expect(defaults.string(forKey: AlternateAppIconSettings.storageKey) == nil)
        #expect(applied == [.quiet])
    }
}
