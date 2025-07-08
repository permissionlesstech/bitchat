//
// ShareViewController.swift
// bitchatShareExtension
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: SLComposeServiceViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Set placeholder text
        placeholder = "Share to bitchat..."
        // Set character limit (optional)
        charactersRemaining = 500
    }
    
    override func isContentValid() -> Bool {
        // Validate that we have text content or attachments
        if let text = contentText, !text.isEmpty {
            return true
        }
        // Check if we have attachments
        if let item = extensionContext?.inputItems.first as? NSExtensionItem,
           let attachments = item.attachments,
           !attachments.isEmpty {
            return true
        }
        return false
    }
    
    override func didSelectPost() {
        // If we have content text from the compose view, handle it directly
        if let text = contentText, !text.isEmpty {
            handleSharedText(text)
            // Complete the share action after saving
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
            return
        }
        
        // Otherwise, process attachments
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        var hasProcessedContent = false
        let group = DispatchGroup()
        
        // Process different types of shared content
        for itemProvider in extensionItem.attachments ?? [] {
            if itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                itemProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] (item, error) in
                    if let text = item as? String {
                        self?.handleSharedText(text)
                        hasProcessedContent = true
                    }
                    group.leave()
                }
            } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                itemProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] (item, error) in
                    if let url = item as? URL {
                        self?.handleSharedURL(url)
                        hasProcessedContent = true
                    }
                    group.leave()
                }
            } else if itemProvider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                itemProvider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { [weak self] (item, error) in
                    if let image = item as? UIImage {
                        self?.handleSharedImage(image)
                        hasProcessedContent = true
                    } else if let data = item as? Data {
                        if let image = UIImage(data: data) {
                            self?.handleSharedImage(image)
                            hasProcessedContent = true
                        }
                    }
                    group.leave()
                }
            }
        }
        
        // Complete after all items are processed
        group.notify(queue: .main) {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }
    
    override func configurationItems() -> [Any]! {
        // No configuration items needed
        return []
    }
    
    // MARK: - Helper Methods
    
    private func handleSharedText(_ text: String) {
        // Save to shared user defaults to pass to main app
        saveToSharedDefaults(content: text, type: "text")
        openMainApp()
    }
    
    private func handleSharedURL(_ url: URL) {
        // Get the page title if available from the extension context
        var pageTitle: String? = nil
        if let item = extensionContext?.inputItems.first as? NSExtensionItem {
            pageTitle = item.attributedContentText?.string ?? item.attributedTitle?.string
        }
        
        // Create a structured format for URL sharing
        let urlData: [String: String] = [
            "url": url.absoluteString,
            "title": pageTitle ?? url.host ?? "Shared Link"
        ]
        
        // Convert to JSON string
        if let jsonData = try? JSONSerialization.data(withJSONObject: urlData),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            saveToSharedDefaults(content: jsonString, type: "url")
        } else {
            // Fallback to simple URL
            saveToSharedDefaults(content: url.absoluteString, type: "url")
        }
        
        openMainApp()
    }
    
    private func handleSharedImage(_ image: UIImage) {
        // For now, we'll just notify that image sharing isn't supported
        // In the future, we could implement image sharing via the mesh
        saveToSharedDefaults(content: "Image sharing coming soon!", type: "image")
        openMainApp()
    }
    
    private func saveToSharedDefaults(content: String, type: String) {
        // Use app groups to share data between extension and main app
        guard let userDefaults = UserDefaults(suiteName: "group.chat.bitchat") else {
            print("ShareExtension: Failed to access app group UserDefaults")
            return
        }
        
        userDefaults.set(content, forKey: "sharedContent")
        userDefaults.set(type, forKey: "sharedContentType")
        userDefaults.set(Date(), forKey: "sharedContentDate")
        userDefaults.synchronize()
        
        print("ShareExtension: Saved content of type \(type) to shared defaults")
    }
    
    private func openMainApp() {
        // Note: Share extensions cannot directly open the containing app
        // The user will need to tap on the notification or manually open the app
        // to see the shared content
    }
}