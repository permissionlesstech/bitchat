import Foundation

enum NostrRelayURL {
    static func normalized(_ rawValue: String, defaultScheme: String? = nil) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if !value.contains("://"), let defaultScheme {
            value = "\(defaultScheme)://\(value)"
        }

        guard var components = URLComponents(string: value),
              let rawScheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              !rawHost.isEmpty else {
            return nil
        }

        switch rawScheme {
        case "wss", "https":
            components.scheme = "wss"
            if components.port == 443 {
                components.port = nil
            }
        case "ws", "http":
            components.scheme = "ws"
            if components.port == 80 {
                components.port = nil
            }
        default:
            return nil
        }

        components.host = rawHost
        if components.path == "/" {
            components.path = ""
        }
        components.fragment = nil

        return components.string
    }

    static func directoryAddress(_ rawValue: String) -> String? {
        guard var normalized = normalized(rawValue, defaultScheme: "wss") else { return nil }
        for prefix in ["wss://", "ws://"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            break
        }
        return normalized
    }
}
