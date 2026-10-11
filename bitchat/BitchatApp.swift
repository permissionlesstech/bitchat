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

    @StateObject private var appLock = AppLockModel()

    init() {
        _runtime = StateObject(wrappedValue: AppRuntime())
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
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

                // The macOS lock surface, and the only one there: no
                // UIWindow path, and macOS locks at launch only, so no
                // AppKit sheet is ever already open over it. On iOS the
                // gate is hosted solely by AppLockWindow (below): a cover
                // drawn here sits under the UIKit modal layer, so a
                // .sheet/.fullScreenCover would show through it.
                #if os(macOS)
                if appLock.isLocked {
                    AppLockScreen(model: appLock)
                        .environment(\.appTheme, AppTheme(rawValue: appThemeRawValue) ?? .matrix)
                }
                #endif
            }
            #if os(iOS)
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    appLock.lockIfEnabled()
                }
                // Retry: `setLocked` gives up when no window scene is
                // connected yet, and since iOS no longer draws an in-tree
                // cover, a creation missed at subscription time would leave
                // the app ungated with nothing to trigger a second attempt.
                // A scene is certainly connected by the time a phase change
                // arrives. Reading the property is correct here — @Published
                // fires in willSet, so only the closure below sees the new
                // value early.
                syncAppLockWindow(appLock.isLocked)
            }
            // The lock's only host on iOS: a dedicated window above the
            // modal layer. Subscribed rather than .onChange so the launch
            // value arrives too — a cold launch is already locked and never
            // transitions, yet a notification tap can select a conversation
            // and present a sheet over the lock.
            .onReceive(appLock.$isLocked) { locked in
                syncAppLockWindow(locked)
            }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif
    }

    #if os(iOS)
    /// Brings the lock window in line with `locked`. Idempotent: `setLocked`
    /// no-ops when a window already exists, so the several places that call
    /// this can overlap freely.
    @MainActor
    private func syncAppLockWindow(_ locked: Bool) {
        AppLockWindow.shared.setLocked(
            locked,
            model: appLock,
            appTheme: AppTheme(rawValue: appThemeRawValue) ?? .matrix
        )
    }
    #endif
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
