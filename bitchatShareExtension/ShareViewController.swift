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
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        
        
        // Get the page title from the compose view or extension item
        let pageTitle = self.contentText ?? extensionItem.attributedContentText?.string ?? extensionItem.attributedTitle?.string
        
        var foundURL: URL? = nil
        let group = DispatchGroup()
        
        // IMPORTANT: Check if the NSExtensionItem itself has a URL
        // Safari often provides the URL as an attributedString with a link
        if let attributedText = extensionItem.attributedContentText {
            let text = attributedText.string
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count))
            if let firstMatch = matches?.first, let url = firstMatch.url {
                foundURL = url
            }
        }
        
        // Only check attachments if we haven't found a URL yet
        if foundURL == nil {
            for (_, itemProvider) in (extensionItem.attachments ?? []).enumerated() {
                
                // Try multiple URL type identifiers that Safari might use
                let urlTypes = [
                    UTType.url.identifier,
                    "public.url",
                    "public.file-url"
                ]
                
                for urlType in urlTypes {
                    if itemProvider.hasItemConformingToTypeIdentifier(urlType) {
                        group.enter()
                        itemProvider.loadItem(forTypeIdentifier: urlType, options: nil) { (item, error) in
                            defer { group.leave() }
                            
                            if let url = item as? URL {
                                foundURL = url
                        } else if let data = item as? Data,
                                  let urlString = String(data: data, encoding: .utf8),
                                  let url = URL(string: urlString) {
                            foundURL = url
                        } else if let string = item as? String,
                                  let url = URL(string: string) {
                            foundURL = url
                        }
                    }
                    break // Found a URL type, no need to check other types
                }
            }
            
            // Also check for plain text that might be a URL
            if foundURL == nil && itemProvider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                itemProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (item, error) in
                    defer { group.leave() }
                    
                    if let text = item as? String {
                        // Check if the text is actually a URL
                        if let url = URL(string: text),
                           (url.scheme == "http" || url.scheme == "https") {
                            foundURL = url
                        }
                    }
                }
            }
        }
        } // End of if foundURL == nil
        
        // Process after all checks complete
        group.notify(queue: .main) { [weak self] in
            if let url = foundURL {
                // We have a URL! Create the JSON data
                let urlData: [String: String] = [
                    "url": url.absoluteString,
                    "title": pageTitle ?? url.host ?? "Shared Link"
                ]
                
                
                if let jsonData = try? JSONSerialization.data(withJSONObject: urlData),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    self?.saveToSharedDefaults(content: jsonString, type: "url")
                }
            } else if let title = pageTitle, !title.isEmpty {
                // No URL found, just share the text
                self?.saveToSharedDefaults(content: title, type: "text")
            }
            
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
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
            return
        }
        
        userDefaults.set(content, forKey: "sharedContent")
        userDefaults.set(type, forKey: "sharedContentType")
        userDefaults.set(Date(), forKey: "sharedContentDate")
        userDefaults.synchronize()
        
        
        // Force open the main app
        self.openMainApp()
    }
    
    private func openMainApp() {
        // Share extensions cannot directly open the containing app
        // The app will check for shared content when it becomes active
        // Show success feedback to user
        DispatchQueue.main.async {
            self.textView.text = "✓ Shared to bitchat"
            self.textView.isEditable = false
        }
    }
}