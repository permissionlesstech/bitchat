import Foundation

enum SharedContentKind: String, Codable, Sendable, Equatable {
    case text
    case url
}

/// The single, bounded payload handed from the share extension to the app.
///
/// The app-group store intentionally contains at most one envelope. A newer
/// share replaces an older one, which prevents unbounded shared-container
/// growth while still surviving suspension and a later app launch.
struct SharedContentPayload: Codable, Sendable, Equatable, Identifiable {
    static let currentVersion = 1
    static let maxContentBytes = 16_000
    static let maxTitleBytes = 512
    static let maxEnvelopeBytes = 24_000
    static let retentionSeconds: TimeInterval = 24 * 60 * 60
    static let allowedFutureSkewSeconds: TimeInterval = 5 * 60

    let version: Int
    let id: UUID
    let kind: SharedContentKind
    let content: String
    let title: String?
    let createdAt: Date

    init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        kind: SharedContentKind,
        content: String,
        title: String? = nil,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.id = id
        self.kind = kind
        self.content = content
        self.title = title
        self.createdAt = createdAt
    }

    static func text(_ content: String, createdAt: Date = Date()) -> SharedContentPayload {
        SharedContentPayload(kind: .text, content: content, createdAt: createdAt)
    }

    var composerText: String { content }

    var preview: String {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.count > 240 else { return normalized }
        return String(normalized.prefix(240)) + "…"
    }

    func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw SharedContentHandoffError.unsupportedVersion
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SharedContentHandoffError.emptyContent
        }
        guard content.utf8.count <= Self.maxContentBytes else {
            throw SharedContentHandoffError.contentTooLarge
        }
        if let title {
            guard title.utf8.count <= Self.maxTitleBytes else {
                throw SharedContentHandoffError.titleTooLarge
            }
            guard !Self.containsDisallowedControl(in: title, allowsTextLayout: false) else {
                throw SharedContentHandoffError.invalidCharacters
            }
        }

        let age = now.timeIntervalSince(createdAt)
        guard age >= -Self.allowedFutureSkewSeconds,
              age <= Self.retentionSeconds else {
            throw SharedContentHandoffError.expired
        }

        switch kind {
        case .text:
            guard !Self.containsDisallowedControl(in: content, allowsTextLayout: true) else {
                throw SharedContentHandoffError.invalidCharacters
            }
        case .url:
            guard !Self.containsDisallowedControl(in: content, allowsTextLayout: false),
                  let components = URLComponents(string: content),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  components.host?.isEmpty == false else {
                throw SharedContentHandoffError.unsupportedURL
            }
        }
    }

    private static func containsDisallowedControl(
        in value: String,
        allowsTextLayout: Bool
    ) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            if allowsTextLayout, scalar == "\n" || scalar == "\r" || scalar == "\t" {
                return false
            }
            return true
        }
    }
}

enum SharedContentHandoffError: Error, Equatable {
    case unsupportedVersion
    case emptyContent
    case contentTooLarge
    case titleTooLarge
    case invalidCharacters
    case expired
    case unsupportedURL
    case envelopeTooLarge
    case encodingFailed
}

/// Durable, single-item app-group storage used by both the extension and app.
final class SharedContentStore {
    static let storageKey = "sharedContentEnvelopeV1"

    private static let legacyKeys = [
        "sharedContent",
        "sharedContentType",
        "sharedContentDate"
    ]

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Replaces any older pending share with a validated, bounded envelope.
    func stage(_ payload: SharedContentPayload, now: Date = Date()) throws {
        try payload.validate(now: now)
        guard let encoded = try? encoder.encode(payload) else {
            throw SharedContentHandoffError.encodingFailed
        }
        guard encoded.count <= SharedContentPayload.maxEnvelopeBytes else {
            throw SharedContentHandoffError.envelopeTooLarge
        }

        defaults.set(encoded, forKey: Self.storageKey)
        clearLegacyKeys()
    }

    /// Reads the pending share without consuming it. Invalid and expired data
    /// is removed immediately so malformed app-group state cannot linger.
    func pending(now: Date = Date()) -> SharedContentPayload? {
        clearLegacyKeys()

        guard let encoded = defaults.data(forKey: Self.storageKey) else { return nil }
        guard encoded.count <= SharedContentPayload.maxEnvelopeBytes,
              let payload = try? decoder.decode(SharedContentPayload.self, from: encoded) else {
            defaults.removeObject(forKey: Self.storageKey)
            return nil
        }

        do {
            try payload.validate(now: now)
            return payload
        } catch {
            defaults.removeObject(forKey: Self.storageKey)
            return nil
        }
    }

    /// Consumes only the envelope the user actually reviewed. If a newer share
    /// already replaced it, the newer content remains pending.
    func consume(id: UUID, now: Date = Date()) -> SharedContentPayload? {
        guard let payload = pending(now: now), payload.id == id else { return nil }
        defaults.removeObject(forKey: Self.storageKey)
        return payload
    }

    /// Explicit cancellation has the same identity guard as consumption so it
    /// can never discard a newer share that arrived while a prompt was open.
    func discard(id: UUID) {
        guard let encoded = defaults.data(forKey: Self.storageKey),
              encoded.count <= SharedContentPayload.maxEnvelopeBytes,
              let payload = try? decoder.decode(SharedContentPayload.self, from: encoded),
              payload.id == id else {
            return
        }
        defaults.removeObject(forKey: Self.storageKey)
    }

    func discardAll() {
        defaults.removeObject(forKey: Self.storageKey)
        clearLegacyKeys()
    }

    private func clearLegacyKeys() {
        for key in Self.legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
