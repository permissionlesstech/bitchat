//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
import UserNotifications

@main
struct BitchatApp: App {
    static let bundleID = Bundle.main.bundleIdentifier ?? "chat.bitchat"
    static let groupID = resolvedGroupID(
        infoDictionary: Bundle.main.infoDictionary,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    static func resolvedGroupID(
        infoDictionary: [String: Any]?,
        bundleIdentifier: String?
    ) -> String {
        if let configured = (infoDictionary?["AppGroupID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           !configured.contains("$(") {
            return configured
        }
        let resolvedBundleID = bundleIdentifier ?? "chat.bitchat"
        return "group.\(resolvedBundleID)"
    }

    /// Returns shared `UserDefaults` for the configured App Group only when the
    /// running binary is entitled to that container. Calling
    /// `UserDefaults(suiteName:)` for an unprovisioned App Group detaches from
    /// `cfprefsd` and logs `Container: (null)` on every launch.
    static func sharedUserDefaults(
        groupID: String = BitchatApp.groupID,
        containerURLProvider: (String) -> URL? = {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        },
        defaultsProvider: (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) -> UserDefaults? {
        guard containerURLProvider(groupID) != nil else { return nil }
        return defaultsProvider(groupID)
    }

    @StateObject private var runtime: AppRuntime
    @AppStorage(AppTheme.storageKey) private var appThemeRawValue = AppTheme.matrix.rawValue
    #if os(iOS)
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    #endif

    init() {
        _runtime = StateObject(wrappedValue: AppRuntime())
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.appTheme, AppTheme(rawValue: appThemeRawValue) ?? .matrix)
                .installAppEnvironment(runtime.environmentModels)
                .onAppear {
                    appDelegate.runtime = runtime
                    runtime.start()
                }
                .onOpenURL { url in
                    runtime.handleOpenURL(url)
                }
                #if os(iOS)
                .onChange(of: scenePhase) { newPhase in
                    runtime.handleScenePhaseChange(newPhase)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    runtime.handleDidBecomeActiveNotification()
                }
                #elseif os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    runtime.handleMacDidBecomeActiveNotification()
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var runtime: AppRuntime?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Installed before the first resign-active so the app-switcher snapshot
        // never captures an open conversation.
        PrivacyScreen.shared.install()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        runtime?.applicationWillTerminate()
    }
}
#endif

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.applicationWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
#endif

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var runtime: AppRuntime?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        // Complete only after the response is handled: for a background
        // action (👋 wave) the system may suspend the app the moment the
        // completion handler runs, which would drop the queued send.
        Task { @MainActor in
            self.runtime?.handleNotificationResponse(
                identifier: identifier,
                actionIdentifier: actionIdentifier,
                userInfo: userInfo
            )
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo

        Task {
            let options = await self.runtime?.presentationOptions(
                forNotificationIdentifier: identifier,
                userInfo: userInfo
            ) ?? [.banner, .sound]
            completionHandler(options)
        }
    }
}
