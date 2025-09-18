import Foundation

/// Extension to handle localization in the share extension by accessing the main app's strings
extension String {
    /// Get a localized string from the main app's bundle if possible, falling back to the extension's bundle
    static func localizedFromMainApp(_ key: String, comment: String = "") -> String {
        // First try to get the string from the extension's bundle
        let localValue = NSLocalizedString(key, comment: comment)
        if localValue != key {
            return localValue
        }
        
        // If not found, try to access the main app's bundle through the app group
        if let appGroupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.chat.bitchat"),
           let mainAppBundleURL = findMainAppBundle(in: appGroupURL),
           let mainBundle = Bundle(url: mainAppBundleURL) {
            
            // Try to get the string from the main app's bundle
            let mainValue = NSLocalizedString(key, bundle: mainBundle, comment: comment)
            if mainValue != key {
                return mainValue
            }
        }
        
        // Fallback to the key itself if not found anywhere
        return key
    }
    
    /// Find the main app's bundle in the shared container
    private static func findMainAppBundle(in containerURL: URL) -> URL? {
        // Common paths for the main app bundle relative to the container
        let possiblePaths = [
            "../bitchat.app",
            "../../Containers/bitchat/Data/Bundle/Application/bitchat.app"
        ]
        
        for path in possiblePaths {
            let potentialURL = containerURL.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: potentialURL.path) {
                return potentialURL
            }
        }
        
        // If we couldn't find the app bundle directly, try to search for it
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil)
            for url in contents {
                if url.lastPathComponent.contains("bitchat") && url.pathExtension == "app" {
                    return url
                }
            }
        } catch {
            print("Error searching for main app bundle: \(error)")
        }
        
        return nil
    }
}
