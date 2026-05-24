import Combine
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
public final class TorManager: ObservableObject {
    public static let shared = TorManager()

    @Published public private(set) var isReady: Bool = true

    public var torEnforced: Bool { false }

    private var foreground = true
    private var autoStartAllowed = false

    private init() {}

    public func startIfNeeded() {}

    public func setAppForeground(_ foreground: Bool) {
        self.foreground = foreground
    }

    public func isForeground() -> Bool {
        foreground
    }

    nonisolated public func awaitReady(timeout: TimeInterval = 25.0) async -> Bool {
        true
    }

    public func ensureRunningOnForeground() {}

    public func goDormantOnBackground() {}

    public func shutdownCompletely() {}

    public func setAutoStartAllowed(_ allow: Bool) {
        autoStartAllowed = allow
    }

    public func isAutoStartAllowed() -> Bool {
        autoStartAllowed
    }
}

public final class TorURLSession {
    public static let shared = TorURLSession()

    private var defaultSession = URLSession(configuration: .default)

    private init() {}

    public var session: URLSession {
        defaultSession
    }

    public func rebuild() {
        defaultSession = URLSession(configuration: .default)
    }

    public func setProxyMode(useTor: Bool) {}
}

public extension Notification.Name {
    static let TorDidBecomeReady = Notification.Name("TorDidBecomeReady")
    static let TorWillRestart = Notification.Name("TorWillRestart")
    static let TorWillStart = Notification.Name("TorWillStart")
    static let TorUserPreferenceChanged = Notification.Name("TorUserPreferenceChanged")
}
