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
    @StateObject private var themeManager = ThemeManager.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif
    
    init() {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chatViewModel)
                .environmentObject(themeManager)
                .onAppear {
                    NotificationDelegate.shared.chatViewModel = chatViewModel
                    #if os(iOS)
                    appDelegate.chatViewModel = chatViewModel
                    #endif
                    // Check for shared content
                    checkForSharedContent()
                }
                .onOpenURL { url in
                    handleURL(url)
                }
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    // Check for shared content when app becomes active
                    checkForSharedContent()
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
            print("DEBUG: Failed to access app group UserDefaults")
            return
        }
        
        guard let sharedContent = userDefaults.string(forKey: "sharedContent"),
              let sharedDate = userDefaults.object(forKey: "sharedContentDate") as? Date else {
            print("DEBUG: No shared content found in UserDefaults")
            return
        }
        
        print("DEBUG: Found shared content: \(sharedContent)")
        print("DEBUG: Shared date: \(sharedDate)")
        print("DEBUG: Time since shared: \(Date().timeIntervalSince(sharedDate)) seconds")
        
        // Only process if shared within last 30 seconds
        if Date().timeIntervalSince(sharedDate) < 30 {
            let contentType = userDefaults.string(forKey: "sharedContentType") ?? "text"
            print("DEBUG: Content type: \(contentType)")
            
            // Clear the shared content
            userDefaults.removeObject(forKey: "sharedContent")
            userDefaults.removeObject(forKey: "sharedContentType")
            userDefaults.removeObject(forKey: "sharedContentDate")
            userDefaults.synchronize()
            
            // Show notification about shared content
            DispatchQueue.main.async {
                // Add system message about sharing
                let systemMessage = BitchatMessage(
                    sender: "system",
                    content: "preparing to share \(contentType)...",
                    timestamp: Date(),
                    isRelay: false
                )
                self.chatViewModel.messages.append(systemMessage)
            }
            
            // Send the shared content after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if contentType == "url" {
                    print("DEBUG: Processing URL content")
                    // Try to parse as JSON first
                    if let data = sharedContent.data(using: .utf8),
                       let urlData = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                       let url = urlData["url"],
                       let title = urlData["title"] {
                        // Send just emoji with hidden markdown link
                        let markdownLink = "👇 [\(title)](\(url))"
                        print("DEBUG: Sending markdown link: \(markdownLink)")
                        self.chatViewModel.sendMessage(markdownLink)
                    } else {
                        // Fallback to simple URL
                        print("DEBUG: Failed to parse JSON, sending as plain URL")
                        self.chatViewModel.sendMessage("Shared link: \(sharedContent)")
                    }
                } else {
                    print("DEBUG: Sending plain text: \(sharedContent)")
                    self.chatViewModel.sendMessage(sharedContent)
                }
            }
        } else {
            print("DEBUG: Shared content is too old, ignoring")
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

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    weak var chatViewModel: ChatViewModel?
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        
        // Check if this is a private message notification
        if identifier.hasPrefix("private-") {
            // Extract sender from notification title
            let title = response.notification.request.content.title
            if let senderName = title.replacingOccurrences(of: "Private message from ", with: "").nilIfEmpty {
                // Find peer ID and open chat
                if let peerID = chatViewModel?.getPeerIDForNickname(senderName) {
                    DispatchQueue.main.async {
                        self.chatViewModel?.startPrivateChat(with: peerID)
                    }
                }
            }
        }
        
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show notification even when app is in foreground (for testing)
        completionHandler([.banner, .sound])
    }
}

extension String {
    var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}