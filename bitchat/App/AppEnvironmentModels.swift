import Foundation
import SwiftUI

/// Non-observing bundle of feature models injected once at the app root.
///
/// Views that only need to forward models into `.sheet` presentations (#1558)
/// or invoke methods inside action closures read `@Environment(\.appEnvironmentModels)`
/// instead of declaring unused `@EnvironmentObject` subscriptions that would
/// invalidate their `body` on unrelated model publishes.
struct AppEnvironmentModels: Equatable {
    let publicChatModel: PublicChatModel
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let composerAutocompleteModel: ComposerAutocompleteModel
    let locationChannelsModel: LocationChannelsModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel
    let boardAlertsModel: BoardAlertsModel
    let sharedContentImportModel: SharedContentImportModel

    static func == (lhs: AppEnvironmentModels, rhs: AppEnvironmentModels) -> Bool {
        lhs.publicChatModel === rhs.publicChatModel
            && lhs.privateInboxModel === rhs.privateInboxModel
            && lhs.privateConversationModel === rhs.privateConversationModel
            && lhs.verificationModel === rhs.verificationModel
            && lhs.conversationUIModel === rhs.conversationUIModel
            && lhs.composerAutocompleteModel === rhs.composerAutocompleteModel
            && lhs.locationChannelsModel === rhs.locationChannelsModel
            && lhs.peerListModel === rhs.peerListModel
            && lhs.appChromeModel === rhs.appChromeModel
            && lhs.boardAlertsModel === rhs.boardAlertsModel
            && lhs.sharedContentImportModel === rhs.sharedContentImportModel
    }
}

private struct AppEnvironmentModelsKey: EnvironmentKey {
    static let defaultValue: AppEnvironmentModels? = nil
}

private struct ComposerDraftModelKey: EnvironmentKey {
    static let defaultValue: ComposerDraftModel? = nil
}

extension EnvironmentValues {
    var appEnvironmentModels: AppEnvironmentModels? {
        get { self[AppEnvironmentModelsKey.self] }
        set { self[AppEnvironmentModelsKey.self] = newValue }
    }

    var composerDraftModel: ComposerDraftModel? {
        get { self[ComposerDraftModelKey.self] }
        set { self[ComposerDraftModelKey.self] = newValue }
    }
}

extension Optional where Wrapped == AppEnvironmentModels {
    /// Unwraps the non-observing environment bundle, flagging missing
    /// `.installAppEnvironment(_:)` wiring in debug builds outside previews.
    func require(
        _ context: StaticString,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> AppEnvironmentModels? {
        if let self {
            return self
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" {
            assertionFailure(
                "Missing AppEnvironmentModels in \(context); install via .installAppEnvironment(_:)",
                file: file,
                line: line
            )
        }
        #endif
        return nil
    }
}

extension View {
    func installAppEnvironment(_ models: AppEnvironmentModels) -> some View {
        self
            .environment(\.appEnvironmentModels, models)
            .environmentObject(models.publicChatModel)
            .environmentObject(models.privateInboxModel)
            .environmentObject(models.privateConversationModel)
            .environmentObject(models.verificationModel)
            .environmentObject(models.conversationUIModel)
            .environmentObject(models.composerAutocompleteModel)
            .environmentObject(models.locationChannelsModel)
            .environmentObject(models.peerListModel)
            .environmentObject(models.appChromeModel)
            .environmentObject(models.boardAlertsModel)
            .environmentObject(models.sharedContentImportModel)
    }
}
