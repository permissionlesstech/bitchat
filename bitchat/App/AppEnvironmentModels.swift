import SwiftUI

/// Non-observing bundle of feature models injected once at the app root.
///
/// Views that only need to forward models into `.sheet` presentations (#1558)
/// or invoke methods inside action closures read `@Environment(\.appEnvironmentModels)`
/// instead of declaring unused `@EnvironmentObject` subscriptions that would
/// invalidate their `body` on unrelated model publishes.
struct AppEnvironmentModels {
    let publicChatModel: PublicChatModel
    let privateInboxModel: PrivateInboxModel
    let privateConversationModel: PrivateConversationModel
    let verificationModel: VerificationModel
    let conversationUIModel: ConversationUIModel
    let composerAutocompleteModel: ComposerAutocompleteModel
    let composerDraftModel: ComposerDraftModel
    let locationChannelsModel: LocationChannelsModel
    let peerListModel: PeerListModel
    let appChromeModel: AppChromeModel
    let boardAlertsModel: BoardAlertsModel
    let sharedContentImportModel: SharedContentImportModel
}

private struct AppEnvironmentModelsKey: EnvironmentKey {
    static let defaultValue: AppEnvironmentModels? = nil
}

extension EnvironmentValues {
    var appEnvironmentModels: AppEnvironmentModels? {
        get { self[AppEnvironmentModelsKey.self] }
        set { self[AppEnvironmentModelsKey.self] = newValue }
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
