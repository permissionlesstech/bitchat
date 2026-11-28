import Testing
@testable import bitchat

struct CommandSuggestionNavigationTests {
    private let commands: [CommandSuggestionNavigation.Command] = [
        .init(alias: "/help", hasPlaceholder: false),
        .init(alias: "/hug", hasPlaceholder: true),
        .init(alias: "/msg", hasPlaceholder: true),
        .init(alias: "/who", hasPlaceholder: false)
    ]

    @Test func incompletePrefixOffersMatchesAndReturnInserts() {
        let panel = CommandSuggestionNavigation.panel(typedText: "/h", commands: commands)
        #expect(panel?.aliases == ["/help", "/hug"])
        #expect(panel?.isUsageReminder == false)
        #expect(panel?.typedIsCompleteCommand == false)
        #expect(panel.map(CommandSuggestionNavigation.returnInserts) == true)
    }

    @Test func finishedAliasStillSendsOnReturn() {
        let panel = CommandSuggestionNavigation.panel(typedText: "/help", commands: commands)
        #expect(panel?.aliases == ["/help"])
        #expect(panel?.typedIsCompleteCommand == true)
        #expect(panel.map(CommandSuggestionNavigation.returnInserts) == false)
    }

    @Test func argumentsKeepTheUsageRowAndSendOnReturn() {
        let panel = CommandSuggestionNavigation.panel(typedText: "/msg alice", commands: commands)
        #expect(panel?.aliases == ["/msg"])
        #expect(panel?.isUsageReminder == true)
        #expect(panel.map(CommandSuggestionNavigation.returnInserts) == false)
    }

    @Test func commandWithoutArgumentsHidesOnceArgumentsStart() {
        let panel = CommandSuggestionNavigation.panel(typedText: "/help now", commands: commands)
        #expect(panel == nil)
    }

    @Test func plainTextHasNoPanel() {
        #expect(CommandSuggestionNavigation.panel(typedText: "hello", commands: commands) == nil)
    }

    @Test func arrowsWrap() {
        #expect(CommandSuggestionNavigation.moved(0, by: -1, count: 3) == 2)
        #expect(CommandSuggestionNavigation.moved(2, by: 1, count: 3) == 0)
        #expect(CommandSuggestionNavigation.moved(1, by: 1, count: 3) == 2)
    }
}
