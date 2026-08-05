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
    static let groupID = "group.\(bundleID)"

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
                .environmentObject(runtime.publicChatModel)
                .environmentObject(runtime.privateInboxModel)
                .environmentObject(runtime.privateConversationModel)
                .environmentObject(runtime.verificationModel)
                .environmentObject(runtime.conversationUIModel)
                .environmentObject(runtime.locationChannelsModel)
                .environmentObject(runtime.peerListModel)
                .environmentObject(runtime.appChromeModel)
                .environmentObject(runtime.boardAlertsModel)
                .environmentObject(runtime.sharedContentImportModel)
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
    /// Holds off App Nap while bitchat is open so Tor + BLE keep serving
    /// neighbors when the window is minimized or another app is focused (#1593).
    private var relayActivity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        relayActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keep Tor and BLE mesh relay alive while bitchat is open"
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let relayActivity {
            ProcessInfo.processInfo.endActivity(relayActivity)
            self.relayActivity = nil
        }
        runtime?.applicationWillTerminate()
    }

    /// Closing the last window should leave the dock process running so a
    /// minimized/hidden macOS install can keep relaying (#1593). Quit via
    /// the menu / Cmd+Q still tears everything down.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock / Cmd-click reopen after the last window was closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // SwiftUI WindowGroup will create a window when we activate; make
            // sure the app comes forward so Tor/BLE stay user-visible again.
            sender.activate(ignoringOtherApps: true)
        }
        return true
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
