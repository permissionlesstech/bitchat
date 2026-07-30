import Foundation

/// What the app is currently able to say about the route it is building.
///
/// A value rather than a finished sentence because the text has two audiences
/// with incompatible rules: `SecureLogger` and `NSError` want stable English a
/// bug report can be grepped for, while the settings screen owes the reader
/// their own language. Formatting the sentence in this package could only ever
/// serve the first, because the string catalog lives in the app target -- which
/// is how these lines reached the UI in English in the first place.
public enum TorTransportDiagnostic: Equatable, Sendable {
    case routeMismatch
    case notReadyBeforeTimeout
    case configurationFailed
    case socksListenerFailed
    case bootstrapFailed
    case stoppedBeforeReady
    case listenerReady(TorTransport)
    case handoffConfigured(TorTransport)
    case proxyOpened(TorTransport)
    case bridgeRequestSent(TorTransport)
    case proxyConnected(TorTransport)
    case proxyRetrying(TorTransport)
    case routeStopped(TorTransport)

    /// Stable English for logs and `NSError`, never for the screen.
    ///
    /// Deliberately identical to the strings these cases replaced, so existing
    /// bug reports and log greps keep matching.
    public var logDescription: String {
        switch self {
        case .routeMismatch:
            return "internal route mismatch; tor was not started"
        case .notReadyBeforeTimeout:
            return "tor did not become ready before the timeout"
        case .configurationFailed:
            return "tor configuration failed"
        case .socksListenerFailed:
            return "the local tor proxy could not start"
        case .bootstrapFailed:
            return "tor bootstrap failed"
        case .stoppedBeforeReady:
            return "tor stopped before becoming ready"
        case .listenerReady(let transport):
            return "\(transport.rawValue) listener ready; configuring tor handoff"
        case .handoffConfigured(let transport):
            return "tor handoff to \(transport.rawValue) configured; waiting for proxy connection"
        case .proxyOpened(let transport):
            return "tor opened \(transport.rawValue); connecting to its local listener"
        case .bridgeRequestSent(let transport):
            return "\(transport.rawValue) received tor's bridge request; finding a proxy"
        case .proxyConnected(let transport):
            return "\(transport.rawValue) proxy connected; bootstrapping tor"
        case .proxyRetrying(let transport):
            return "\(transport.rawValue) could not connect to a proxy; retrying"
        case .routeStopped(let transport):
            return "\(transport.rawValue) stopped unexpectedly"
        }
    }
}
