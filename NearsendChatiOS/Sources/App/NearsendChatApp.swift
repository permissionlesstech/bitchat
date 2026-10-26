import SwiftUI

@main
struct NearsendChatApp: App {
    @StateObject private var store = ChatStore()
    @AppStorage("onboarded") private var onboarded = false

    init() {
        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = UIBlurEffect(style: .systemThinMaterial)
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }

    var body: some Scene {
        WindowGroup {
            LanguageRoot {
                if onboarded { RootView() } else { OnboardingView { onboarded = true } }
            }
            .environmentObject(store)
            .tint(Theme.link)
            .onAppear { if onboarded { store.startIfNeeded() } }
            .onChange(of: onboarded) { _, v in if v { store.startIfNeeded() } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: ChatStore
    @AppStorage("tab") private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NearbyView().tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            ChatsView().tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(store.unreadTotal).tag(1)
            IdentityView().tabItem { Label("You", systemImage: "person.crop.circle.fill") }.tag(2)
        }
    }
}

struct AppLanguage: Identifiable {
    let code: String, name: String
    var id: String { code }
    /// Each language is listed in its own language so people can find it whatever the app is currently showing.
    static let all: [AppLanguage] = [
        .init(code: "en", name: "English"), .init(code: "sv", name: "Svenska"), .init(code: "es", name: "Español"),
        .init(code: "fr", name: "Français"), .init(code: "de", name: "Deutsch"), .init(code: "pt", name: "Português"),
        .init(code: "it", name: "Italiano"), .init(code: "ar", name: "العربية"), .init(code: "tr", name: "Türkçe"),
        .init(code: "ru", name: "Русский"), .init(code: "zh-Hans", name: "简体中文"), .init(code: "ja", name: "日本語"),
    ]
}

/// Follows the phone's language by default; the "language" setting overrides it (and flips layout for right-to-left languages).
struct LanguageRoot<Content: View>: View {
    @AppStorage("language") private var language = "system"
    @Environment(\.layoutDirection) private var systemDirection
    @ViewBuilder var content: Content

    var body: some View {
        let explicit = language != "system"
        content
            .environment(\.locale, explicit ? Locale(identifier: language) : Locale.autoupdatingCurrent)
            .environment(\.layoutDirection, explicit
                ? (Locale.Language(identifier: language).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
                : systemDirection)
    }
}
