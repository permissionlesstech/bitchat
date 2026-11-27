import Testing
@testable import bitchat

struct BridgeCaptionTests {
    @Test func noCellKeepsTheEmptyCaption() {
        #expect(BridgeSettingsCaption.resolve(hasCell: false, people: 4) == .noCell)
    }

    @Test func aCellWithNobodyOmitsTheCount() {
        #expect(BridgeSettingsCaption.resolve(hasCell: true, people: 0) == .cell)
    }

    @Test func aCellWithPeopleIncludesTheCount() {
        #expect(BridgeSettingsCaption.resolve(hasCell: true, people: 1) == .cellAndPeople)
        #expect(BridgeSettingsCaption.resolve(hasCell: true, people: 12) == .cellAndPeople)
    }
}
