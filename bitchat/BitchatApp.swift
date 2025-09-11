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
    @StateObject private var chatViewModel = ChatViewModel()
    #if os(iOS)
    @Environment(\.scenePhase) var scenePhase
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // Skip the very first .active-triggered Tor restart on cold launch
    @State private var didHandleInitialActive: Bool = false
    @State private var didEnterBackground: Bool = false
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    #endif
    
    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // Warm up georelay directory and refresh if stale (once/day)
        GeoRelayDirectory.shared.prefetchIfNeeded()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chatViewModel)
                .onAppear {
                    NotificationDelegate.shared.chatViewModel = chatViewModel
                    // Inject live Noise service into VerificationService to avoid creating new BLE instances
                    VerificationService.shared.configure(with: chatViewModel.meshService.getNoiseService())
                    // Prewarm Nostr identity and QR to make first VERIFY sheet fast
                    DispatchQueue.global(qos: .utility).async {
                        let npub = try? NostrIdentityBridge.getCurrentNostrIdentity()?.npub
                        _ = VerificationService.shared.buildMyQRString(nickname: chatViewModel.nickname, npub: npub)
                    }
                    #if os(iOS)
                    appDelegate.chatViewModel = chatViewModel
                    #elseif os(macOS)
                    appDelegate.chatViewModel = chatViewModel
                    #endif
                    // Spin up Tor early; all internet will gate on Tor 100%
                    TorManager.shared.startIfNeeded()
                    // Check for shared content
                    checkForSharedContent()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
                #if os(iOS)
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        // Keep BLE mesh running in background; BLEService adapts scanning automatically
                        // Optionally nudge Tor to dormant to save power
                        TorManager.shared.setAppForeground(false)
                        TorManager.shared.goDormantOnBackground()
                        // Stop geohash sampling while backgrounded
                        Task { @MainActor in
                            chatViewModel.endGeohashSampling()
                        }
                        // Proactively disconnect Nostr to avoid spurious socket errors while Tor is down
                        NostrRelayManager.shared.disconnect()
                        didEnterBackground = true
                    case .active:
                        // Restart services when becoming active
                        chatViewModel.meshService.startServices()
                        TorManager.shared.setAppForeground(true)
                        // On initial cold launch, Tor was just started in onAppear.
                        // Skip the deterministic restart the first time we become active.
                        if didHandleInitialActive && didEnterBackground {
                            TorManager.shared.ensureRunningOnForeground()
                        } else {
                            didHandleInitialActive = true
                        }
                        didEnterBackground = false
                        Task.detached {
                            let _ = await TorManager.shared.awaitReady(timeout: 60)
                            await MainActor.run {
                                // Rebuild proxied sessions to bind to the live Tor after readiness
                                TorURLSession.shared.rebuild()
                                // Reconnect Nostr via fresh sessions; will gate until Tor 100%
                                NostrRelayManager.shared.resetAllConnections()
                            }
                        }
                        checkForSharedContent()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Check for shared content when app becomes active
                    checkForSharedContent()
                }
                #elseif os(macOS)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    // App became active
                }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif
    }
    
    private func handleURL(_ url: URL) {
        if url.scheme == "bitchat" && url.host == "share" {
            // Handle shared content
            checkForSharedContent()
        }
    }
    
    private func checkForSharedContent() {
        // Check app group for shared content from extension
        guard let userDefaults = UserDefaults(suiteName: "group.chat.bitchat") else {
            return
        }
        
        guard let sharedContent = userDefaults.string(forKey: "sharedContent"),
              let sharedDate = userDefaults.object(forKey: "sharedContentDate") as? Date else {
            return
        }
        
        // Only process if shared within configured window
        if Date().timeIntervalSince(sharedDate) < TransportConfig.uiShareAcceptWindowSeconds {
            let contentType = userDefaults.string(forKey: "sharedContentType") ?? "text"
            
            // Clear the shared content
            userDefaults.removeObject(forKey: "sharedContent")
            userDefaults.removeObject(forKey: "sharedContentType")
            userDefaults.removeObject(forKey: "sharedContentDate")
            // No need to force synchronize here
            
            // Send the shared content immediately on the main queue
            DispatchQueue.main.async {
                if contentType == "url" {
                    // Try to parse as JSON first
                    if let data = sharedContent.data(using: .utf8),
                       let urlData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let url = urlData["url"] {
                        // Send plain URL
                        self.chatViewModel.sendMessage(url)
                    } else {
                        // Fallback to simple URL
                        self.chatViewModel.sendMessage(sharedContent)
                    }
                } else {
                    self.chatViewModel.sendMessage(sharedContent)
                }
            }
        }
    }
}

#if os(iOS)
class AppDelegate: NSObject, UIApplicationDelegate {
    weak var chatViewModel: ChatViewModel?
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        return true
    }
}
#endif

#if os(macOS)
import AppKit

class MacAppDelegate: NSObject, NSApplicationDelegate {
    weak var chatViewModel: ChatViewModel?
    
    func applicationWillTerminate(_ notification: Notification) {
        chatViewModel?.applicationWillTerminate()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
#endif

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var chatViewModel: ChatViewModel?
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let userInfo = response.notification.request.content.userInfo
        
        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Get peer ID from userInfo
            if let peerID = userInfo["peerID"] as? String {
                DispatchQueue.main.async {
                    self.chatViewModel?.startPrivateChat(with: peerID)
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
                if chatViewModel?.selectedPrivateChatPeer == peerID {
                    completionHandler([])
                    return
                }
            }
        }
        // Suppress geohash activity notification if we're already in that geohash channel
        if identifier.hasPrefix("geo-activity-"),
           let deep = userInfo["deeplink"] as? String,
           let gh = deep.components(separatedBy: "/").last {
            if case .location(let ch) = LocationChannelManager.shared.selectedChannel, ch.geohash == gh {
                completionHandler([])
                return
            }
        }
        
        // Show notification in all other cases
        completionHandler([.banner, .sound])
    }
}

extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
