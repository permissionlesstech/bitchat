import Foundation

#if os(iOS) && canImport(IPtProxy)
import IPtProxy
#endif

public enum TorTransportMode: String, Codable, CaseIterable, Sendable {
    case direct
    case auto
    case obfs4
    case snowflake
}

public enum TorTransportStorageKeys {
    public static let mode = "tor.transport.mode"
    public static let lastSuccessfulTransport = "tor.transport.lastSuccessful"
}

public enum TorTransport: String, Codable, CaseIterable, Sendable {
    case direct
    case obfs4
    case snowflake

    /// Upper bound on a bootstrap attempt. This is a ceiling, not a budget:
    /// `TorManager` gives up earlier when progress stops advancing. Snowflake
    /// pulls the directory over a lossy WebRTC hop and needs minutes on a cold
    /// cache, so a tight ceiling killed attempts that were still working.
    public var bootstrapDeadline: TimeInterval {
        switch self {
        case .direct: 45
        case .obfs4: 120
        case .snowflake: 300
        }
    }

    /// Seconds without forward progress before the route is called blocked.
    ///
    /// Each transport keeps its own directory cache, so a bridged route
    /// downloads the whole Tor directory on every cold start. That download
    /// plateaus while circuits are retried, and the plateau is longer the
    /// slower the hop, so a single shared window read healthy Snowflake
    /// attempts as failures.
    public var bootstrapStallWindow: Int {
        switch self {
        case .direct: 30
        case .obfs4: 90
        case .snowflake: 120
        }
    }
}

public enum TorTransportLifecycle: String, Codable, Sendable {
    case idle
    case starting
    case ready
    case stalled
    case failed
}

public struct TorTransportStatus: Equatable, Sendable {
    public let transport: TorTransport?
    public let lifecycle: TorTransportLifecycle
    public let attempted: [TorTransport]

    public init(
        transport: TorTransport?,
        lifecycle: TorTransportLifecycle,
        attempted: [TorTransport]
    ) {
        self.transport = transport
        self.lifecycle = lifecycle
        self.attempted = attempted
    }

    public static let idle = TorTransportStatus(
        transport: nil,
        lifecycle: .idle,
        attempted: []
    )
}

enum TorForegroundRecoveryAction: Equatable {
    case none
    case continueCurrentAttempt
    case deferUntilShutdownCompletes
    case restart
}

enum TorLifecyclePolicy {
    static func foregroundRecoveryAction(
        autoStartAllowed: Bool,
        isForeground: Bool,
        isReady: Bool,
        isRestarting: Bool,
        shutdownInFlight: Bool,
        artiIsRunning: Bool
    ) -> TorForegroundRecoveryAction {
        guard autoStartAllowed, isForeground, !isReady, !isRestarting else {
            return .none
        }
        if shutdownInFlight {
            return .deferUntilShutdownCompletes
        }
        if artiIsRunning {
            return .continueCurrentAttempt
        }
        return .restart
    }
}

enum TorBootstrapWaitOutcome: Equatable {
    case ready
    case keepWaiting
    /// Progress stood still long enough to call the route blocked.
    case stalled
    /// Still advancing, but out of time.
    case ceilingReached
}

enum TorBootstrapWaitPolicy {
    /// Decides whether to keep waiting on a bootstrap that has not finished.
    ///
    /// Separating "stopped advancing" from "ran out of time" is the point.
    /// Snowflake fetches the directory over a lossy hop and retries visibly,
    /// so elapsed time alone says nothing about whether a route is blocked.
    static func outcome(
        progress: Int,
        highWaterProgress: Int,
        secondsSinceProgress: Int,
        remainingSeconds: Int,
        stallWindow: Int
    ) -> TorBootstrapWaitOutcome {
        if progress >= 100 { return .ready }
        if progress > highWaterProgress { return .keepWaiting }
        if secondsSinceProgress >= stallWindow { return .stalled }
        return remainingSeconds > 0 ? .keepWaiting : .ceilingReached
    }
}

enum TorTransportEventOutcome: Equatable {
    case ignore
    case proxyConnected
    case proxyRetrying
    case ignoreStopWhileArtiOwnsRoute
    case routeStopped
}

enum TorTransportEventPolicy {
    /// Folds IPtProxy's per-attempt event stream into one route state.
    ///
    /// Snowflake reports an event per WebRTC peer, so a failure can arrive
    /// after a sibling attempt already connected. Once any attempt connects,
    /// the aggregate must stay connected while Arti bootstraps over it.
    static func outcome(
        for event: PluggableTransportEvent,
        activeTransport: TorTransport?,
        isStarting: Bool,
        isReady: Bool,
        hasConnectedProxy: Bool,
        artiIsRunning: Bool
    ) -> TorTransportEventOutcome {
        let eventTransport: TorTransport
        switch event {
        case .connected(let value),
             .recoverableFailure(let value),
             .stopped(let value):
            eventTransport = value
        }
        guard eventTransport == activeTransport, isStarting || isReady else {
            return .ignore
        }

        switch event {
        case .connected:
            return isStarting ? .proxyConnected : .ignore
        case .recoverableFailure:
            return isStarting && !hasConnectedProxy ? .proxyRetrying : .ignore
        case .stopped:
            return artiIsRunning ? .ignoreStopWhileArtiOwnsRoute : .routeStopped
        }
    }
}

public struct TorRouteConfiguration: Equatable, Sendable {
    public var mode: TorTransportMode
    public var obfs4BridgeLines: [String]
    public var lastSuccessfulTransport: TorTransport?

    public init(
        mode: TorTransportMode = .direct,
        obfs4BridgeLines: [String] = [],
        lastSuccessfulTransport: TorTransport? = nil
    ) {
        self.mode = mode
        self.obfs4BridgeLines = obfs4BridgeLines
        self.lastSuccessfulTransport = lastSuccessfulTransport
    }
}

public enum TorRoutePlanner {
    public static func candidates(
        for configuration: TorRouteConfiguration
    ) -> [TorTransport] {
        switch configuration.mode {
        case .direct:
            return [.direct]
        case .obfs4:
            return configuration.obfs4BridgeLines.isEmpty ? [] : [.obfs4]
        case .snowflake:
            return [.snowflake]
        case .auto:
            var ordered: [TorTransport] = []
            let available: [TorTransport] = configuration.obfs4BridgeLines.isEmpty
                ? [.direct, .snowflake]
                : [.direct, .obfs4, .snowflake]
            if let last = configuration.lastSuccessfulTransport,
               available.contains(last) {
                ordered.append(last)
            }
            for transport in available where !ordered.contains(transport) {
                ordered.append(transport)
            }
            return ordered
        }
    }
}

struct ArtiTransportConfiguration: Encodable {
    let version = 1
    let transport: TorTransport
    let bridgeLines: [String]
    let ptSocksAddress: String?
}

enum PluggableTransportError: Error {
    case unavailable
    case stateDirectory
    case initialization
    case start
    case localAddress
}

enum PluggableTransportEvent: Sendable {
    case connected(TorTransport)
    case recoverableFailure(TorTransport)
    case stopped(TorTransport)
}

@MainActor
protocol PluggableTransportControlling: AnyObject {
    var eventHandler: ((PluggableTransportEvent) -> Void)? { get set }
    func start(_ transport: TorTransport, stateDirectory: URL) throws -> String
    func stop()
}

#if os(iOS) && canImport(IPtProxy)
private final class IPtProxyEventSink: NSObject, IPtProxyOnTransportEventsProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (PluggableTransportEvent) -> Void
    private var activeTransport: TorTransport?

    init(handler: @escaping @Sendable (PluggableTransportEvent) -> Void) {
        self.handler = handler
    }

    func activate(_ transport: TorTransport) {
        lock.lock()
        activeTransport = transport
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        activeTransport = nil
        lock.unlock()
    }

    func connected(_ name: String?) {
        guard let transport = currentTransport() else { return }
        handler(.connected(transport))
    }

    func error(_ name: String?, error: Error?) {
        guard let transport = currentTransport() else { return }
        handler(.recoverableFailure(transport))
    }

    func stopped(_ name: String?, error: Error?) {
        let transport = currentTransport()
        guard let transport else { return }
        handler(.stopped(transport))
    }

    private func currentTransport() -> TorTransport? {
        lock.lock()
        defer { lock.unlock() }
        return activeTransport
    }
}

@MainActor
final class IPtProxyTransportController: PluggableTransportControlling {
    // IPtProxy initializes Lyrebird's transport registry process-wide. A
    // second Controller constructor returns a nil Go object that gomobile can
    // still wrap as nonnil Objective-C, and calling it raises an NSException.
    // Keep the one valid controller for the lifetime of this Swift wrapper.
    private var controller: IPtProxyController?
    private var controllerStateDirectory: URL?
    private var activeMethod: String?
    var eventHandler: ((PluggableTransportEvent) -> Void)?
    private lazy var eventSink = IPtProxyEventSink { [weak self] event in
        Task { @MainActor [weak self] in
            self?.eventHandler?(event)
        }
    }

    func start(_ transport: TorTransport, stateDirectory: URL) throws -> String {
        stop()
        guard transport != .direct else { throw PluggableTransportError.unavailable }

        let normalizedStateDirectory = stateDirectory.standardizedFileURL
        try FileManager.default.createDirectory(
            at: normalizedStateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = normalizedStateDirectory
        try? mutableDirectory.setResourceValues(resourceValues)

        let activeController: IPtProxyController
        if let controller {
            guard controllerStateDirectory == normalizedStateDirectory else {
                throw PluggableTransportError.stateDirectory
            }
            activeController = controller
        } else {
            guard let newController = IPtProxyController(
                normalizedStateDirectory.path,
                enableLogging: false,
                unsafeLogging: false,
                logLevel: "ERROR",
                transportEvents: eventSink
            ) else {
                throw PluggableTransportError.initialization
            }
            controller = newController
            controllerStateDirectory = normalizedStateDirectory
            activeController = newController
        }

        let method: String
        switch transport {
        case .direct:
            throw PluggableTransportError.unavailable
        case .obfs4:
            method = IPtProxyObfs4
        case .snowflake:
            method = IPtProxySnowflake
            activeController.snowflakeBrokerUrl = SnowflakeDefaults.brokerURL
            activeController.snowflakeFrontDomains = SnowflakeDefaults.frontDomains
            activeController.snowflakeIceServers = SnowflakeDefaults.iceServers
            activeController.snowflakeMaxPeers = SnowflakeDefaults.maxPeers
        }

        eventSink.activate(transport)
        do {
            try activeController.start(method, proxy: "")
        } catch {
            eventSink.deactivate()
            throw error
        }
        activeMethod = method
        let address = activeController.localAddress(method)
        guard !address.isEmpty else {
            stop()
            throw PluggableTransportError.localAddress
        }
        return address
    }

    func stop() {
        guard let activeMethod else { return }
        self.activeMethod = nil
        eventSink.deactivate()
        controller?.stop(activeMethod)
    }
}
#else
@MainActor
final class IPtProxyTransportController: PluggableTransportControlling {
    var eventHandler: ((PluggableTransportEvent) -> Void)?

    func start(_ transport: TorTransport, stateDirectory: URL) throws -> String {
        throw PluggableTransportError.unavailable
    }

    func stop() {}
}
#endif

enum SnowflakeDefaults {
    // Tor Project Snowflake client defaults, pinned from:
    // gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/snowflake
    // commit cd33fc638ac03343197eb944a611df29f554be88.
    // Its recommended torrc enables these two CDN77 bridges. Other rendezvous
    // methods are alternatives, not additional bridges to enable in parallel.
    static let brokerURL = "https://1098762253.rsc.cdn77.org/"
    static let frontDomains = "www.cdn77.com,www.phpmyadmin.net"
    static let maxPeers: Int = 1
    static let iceServers = [
        "stun:stun.antisip.com:3478",
        "stun:stun.epygi.com:3478",
        "stun:stun.uls.co.za:3478",
        "stun:stun.voipgate.com:3478",
        "stun:stun.mixvoip.com:3478",
        "stun:stun.nextcloud.com:3478",
        "stun:stun.bethesda.net:3478",
        "stun:stun.nextcloud.com:443"
    ].joined(separator: ",")

    static let bridgeLines = [
        "Bridge snowflake 192.0.2.4:80 8838024498816A039FCBBAB14E6F40A0843051FA fingerprint=8838024498816A039FCBBAB14E6F40A0843051FA url=https://1098762253.rsc.cdn77.org/ fronts=www.cdn77.com,www.phpmyadmin.net ice=\(iceServers) utls-imitate=hellorandomizedalpn",
        "Bridge snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://1098762253.rsc.cdn77.org/ fronts=www.cdn77.com,www.phpmyadmin.net ice=\(iceServers) utls-imitate=hellorandomizedalpn"
    ]
}
