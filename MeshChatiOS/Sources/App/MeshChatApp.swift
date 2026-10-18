import SwiftUI

@main
struct MeshChatApp: App {
    @StateObject private var store = MeshStore()
    @AppStorage("onboarded") private var onboarded = false

    init() {
        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboarded { RootView() } else { OnboardingView { onboarded = true } }
            }
            .environmentObject(store)
            .preferredColorScheme(.dark)
            .tint(Theme.mint)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: MeshStore
    @AppStorage("tab") private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            NearbyView().tabItem { Label("Nearby", systemImage: "dot.radiowaves.left.and.right") }.tag(0)
            ChatsView().tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(store.conversations.reduce(0) { $0 + $1.unread }).tag(1)
            IdentityView().tabItem { Label("You", systemImage: "person.crop.circle.fill") }.tag(2)
        }
    }
}
