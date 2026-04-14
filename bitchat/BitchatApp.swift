//
// BitchatApp.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Tor
import SwiftUI
import BitFoundation
import UserNotifications

@main
struct BitchatApp: App {
    static let bundleID = Bundle.main.bundleIdentifier ?? "chat.bitchat"
    static let groupID = "group.\(bundleID)"

    @StateObject private var runtime: AppRuntime
    #if os(iOS)
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    #endif

    init() {
        _runtime = StateObject(wrappedValue: AppRuntime())
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(runtime: runtime)
                .environmentObject(runtime.chatViewModel)
                .environmentObject(runtime.publicTimelineStore)
                .environmentObject(runtime.peerStore)
                .environmentObject(runtime.geohashParticipantStore)
                .environmentObject(runtime.geohashPeopleStore)
                .environmentObject(runtime.sessionStore)
                .environmentObject(runtime.peerPresentationStore)
                .environmentObject(runtime.verificationStore)
                .onAppear {
                    runtime.attach()
                    UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
                    appDelegate.runtime = runtime
                    runtime.start()
                    runtime.checkForSharedContent()
                }
                .onOpenURL { url in
                    runtime.handleURL(url)
                }
                #if os(iOS)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        runtime.enterBackground()
                    case .active:
                        runtime.enterForeground()
                        runtime.checkForSharedContent()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
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
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        runtime?.shutdown()
    }
}
#endif

#if os(macOS)
import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?
    
    func applicationWillTerminate(_ notification: Notification) {
        runtime?.shutdown()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var chatViewModel: ChatViewModel?
    weak var locationManager: LocationChannelManager?
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        
        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                DispatchQueue.main.async {
                    self.chatViewModel?.startPrivateChat(with: PeerID(str: peerID))
                }
            }
        }
        // Handle deeplink (e.g., geohash activity)
        if let deep = userInfo["deeplink"] as? String, let url = URL(string: deep) {
            #if os(iOS)
            DispatchQueue.main.async { UIApplication.shared.open(url) }
            #else
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            #endif
        }
        
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let userInfo = notification.request.content.userInfo
        
        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                // Don't show notification if the private chat is already open
                // Access main-actor-isolated property via Task
                Task { @MainActor in
                    if self.chatViewModel?.selectedPrivateChatPeer == PeerID(str: peerID) {
                        completionHandler([])
                    } else {
                        completionHandler([.banner, .sound])
                    }
                }
                return
            }
        }
        // Suppress geohash activity notification if we're already in that geohash channel
        if identifier.hasPrefix("geo-activity-"),
           let deep = userInfo["deeplink"] as? String,
           let gh = deep.components(separatedBy: "/").last {
            if let locationManager,
               case .location(let ch) = locationManager.selectedChannel,
               ch.geohash == gh {
                completionHandler([])
                return
            }
        }
        
        // Show notification in all other cases
        completionHandler([.banner, .sound])
    }
}
