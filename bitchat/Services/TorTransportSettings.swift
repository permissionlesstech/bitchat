import BitFoundation
import Foundation
import Security
import Tor

enum Obfs4BridgeValidationError: Error, Equatable {
    case inputTooLarge
    case tooManyBridges
    case malformedLine(Int)
    case noBridges
}

@MainActor
final class TorTransportSettings: ObservableObject {
    static let shared = TorTransportSettings()
    static let didChangeNotification = Notification.Name("TorTransportSettingsDidChange")

    static let keychainService = "chat.bitchat.tor.bridges"
    private static let keychainAccount = "obfs4-lines-v1"
    private static let maximumInputBytes = 16 * 1024
    private static let maximumBridges = 8

    @Published private(set) var mode: TorTransportMode
    @Published private(set) var obfs4BridgeLines: [String]
    @Published private(set) var bridgeStorageAvailable: Bool
    /// Set by a panic wipe and cleared only by the user choosing a mode.
    ///
    /// The wipe destroys the bridges the chosen transport depended on, so
    /// there is no route left that the user actually consented to. Until they
    /// pick one, `NetworkActivationService` allows nothing out at all.
    @Published private(set) var requiresTransportSelection: Bool

    private let defaults: UserDefaults
    private let keychain: KeychainManagerProtocol
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainManagerProtocol = KeychainManager.makeDefault(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.notificationCenter = notificationCenter
        mode = defaults
            .string(forKey: TorTransportStorageKeys.mode)
            .flatMap(TorTransportMode.init(rawValue:)) ?? .direct
        requiresTransportSelection = defaults.bool(
            forKey: TorTransportStorageKeys.transportSelectionRequired
        )

        switch keychain.loadWithResult(
            key: Self.keychainAccount,
            service: Self.keychainService
        ) {
        case .success(let data):
            obfs4BridgeLines =
                (try? JSONDecoder().decode([String].self, from: data)) ?? []
            bridgeStorageAvailable = true
        case .itemNotFound:
            obfs4BridgeLines = []
            bridgeStorageAvailable = true
        case .accessDenied, .deviceLocked, .authenticationFailed, .otherError:
            obfs4BridgeLines = []
            bridgeStorageAvailable = false
        }
    }

    var routeConfiguration: TorRouteConfiguration {
        let lastTransport = defaults
            .string(forKey: TorTransportStorageKeys.lastSuccessfulTransport)
            .flatMap(TorTransport.init(rawValue:))
        return TorRouteConfiguration(
            mode: mode,
            obfs4BridgeLines: obfs4BridgeLines,
            lastSuccessfulTransport: lastTransport
        )
    }

    func setMode(_ newMode: TorTransportMode) {
        // Choosing a mode is the consent a post-panic app is waiting for, so
        // it clears the gate even when the mode itself did not change: after a
        // wipe the stored mode is already the default, and re-picking it must
        // still be a way back onto the network.
        let clearedSelectionGate = clearTransportSelectionRequirement()
        guard newMode != mode else {
            if clearedSelectionGate { notifyChanged() }
            return
        }
        mode = newMode
        defaults.set(newMode.rawValue, forKey: TorTransportStorageKeys.mode)
        notifyChanged()
    }

    @discardableResult
    private func clearTransportSelectionRequirement() -> Bool {
        guard requiresTransportSelection else { return false }
        requiresTransportSelection = false
        defaults.removeObject(
            forKey: TorTransportStorageKeys.transportSelectionRequired
        )
        return true
    }

    @discardableResult
    func saveObfs4BridgeInput(
        _ input: String
    ) -> Result<Int, Obfs4BridgeValidationError> {
        switch Self.validateAndNormalize(input) {
        case .failure(let error):
            return .failure(error)
        case .success(let lines):
            guard let encoded = try? JSONEncoder().encode(lines) else {
                return .failure(.malformedLine(1))
            }
            keychain.save(
                key: Self.keychainAccount,
                data: encoded,
                service: Self.keychainService,
                accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
            guard keychain.load(
                key: Self.keychainAccount,
                service: Self.keychainService
            ) == encoded else {
                bridgeStorageAvailable = false
                return .failure(.malformedLine(1))
            }
            bridgeStorageAvailable = true
            obfs4BridgeLines = lines
            notifyChanged()
            return .success(lines.count)
        }
    }

    func clearObfs4Bridges() {
        keychain.delete(
            key: Self.keychainAccount,
            service: Self.keychainService
        )
        obfs4BridgeLines = []
        // Removing bridges must not move the user to a weaker route. Switching
        // to direct here put anyone who cleared or replaced their bridges onto
        // plain Tor without being asked, on the network they had chosen obfs4
        // to hide from. obfs4 with no bridges plans nothing, so tor simply
        // stops until bridges are supplied or another mode is picked, which is
        // the failure the mode promises.
        notifyChanged()
    }

    func resetForPanic() {
        keychain.deleteAll(service: Self.keychainService)
        defaults.removeObject(forKey: TorTransportStorageKeys.mode)
        defaults.removeObject(
            forKey: TorTransportStorageKeys.lastSuccessfulTransport
        )
        mode = .direct
        obfs4BridgeLines = []
        bridgeStorageAvailable = true
        requiresTransportSelection = true
        defaults.set(
            true,
            forKey: TorTransportStorageKeys.transportSelectionRequired
        )
        notifyChanged()
    }

    static func validateAndNormalize(
        _ input: String
    ) -> Result<[String], Obfs4BridgeValidationError> {
        guard input.utf8.count <= maximumInputBytes else {
            return .failure(.inputTooLarge)
        }

        var normalized: [String] = []
        var seen = Set<String>()
        for (offset, rawLine) in input.components(separatedBy: .newlines).enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.lowercased().hasPrefix("bridge ") {
                line = String(line.dropFirst("bridge ".count))
                    .trimmingCharacters(in: .whitespaces)
            }
            guard isStructurallyValidObfs4Line(line) else {
                return .failure(.malformedLine(offset + 1))
            }
            let stored = "Bridge \(line)"
            if seen.insert(stored).inserted {
                normalized.append(stored)
            }
            if normalized.count > maximumBridges {
                return .failure(.tooManyBridges)
            }
        }

        guard !normalized.isEmpty else { return .failure(.noBridges) }
        return .success(normalized)
    }

    private static func isStructurallyValidObfs4Line(_ line: String) -> Bool {
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 5,
              fields[0].lowercased() == "obfs4",
              validHostAndPort(fields[1]) else {
            return false
        }

        let fingerprint = fields[2].hasPrefix("$")
            ? String(fields[2].dropFirst())
            : fields[2]
        guard fingerprint.count == 40,
              fingerprint.allSatisfy(\.isHexDigit) else {
            return false
        }

        var parameters: [String: String] = [:]
        for field in fields.dropFirst(3) {
            guard let (key, value) = field.splitOnce(on: "="),
                  parameters.updateValue(value, forKey: key) == nil else {
                return false
            }
        }
        guard let certificate = parameters["cert"], !certificate.isEmpty,
              let iatMode = parameters["iat-mode"],
              iatMode == "0" || iatMode == "1" else {
            return false
        }
        return true
    }

    private static func validHostAndPort(_ value: String) -> Bool {
        guard let separator = value.lastIndex(of: ":"),
              separator != value.startIndex,
              let port = Int(value[value.index(after: separator)...]),
              (1...65_535).contains(port) else {
            return false
        }
        return true
    }

    private func notifyChanged() {
        notificationCenter.post(name: Self.didChangeNotification, object: self)
    }
}

private extension String {
    func splitOnce(on separator: Character) -> (String, String)? {
        guard let index = firstIndex(of: separator) else { return nil }
        let key = String(self[..<index])
        let value = String(self[self.index(after: index)...])
        guard !key.isEmpty else { return nil }
        return (key, value)
    }
}
