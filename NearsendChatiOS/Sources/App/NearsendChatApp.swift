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
            Group {
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
