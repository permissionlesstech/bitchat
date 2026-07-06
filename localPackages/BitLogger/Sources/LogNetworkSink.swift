//
// LogNetworkSink.swift
// BitLogger
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if DEBUG
import Foundation
#if canImport(Network)
import Network
#endif

/// Best-effort, fire-and-forget UDP forwarder for sanitized log lines, so a
/// sideloaded device on iOS 17+ (where `idevicesyslog` Wi-Fi streaming no
/// longer works) can stream its logs to a LAN collector with no cable.
///
/// Design constraints:
/// - DEBUG-only: never compiled into release. A privacy-first release build
///   carries zero network-log code.
/// - Opt-in and off by default: nothing is ever sent until a collector host
///   is configured. An empty host means no egress.
/// - Never blocks the caller and never throws into the app: every send runs
///   on a private queue and failures are silently dropped. A dead or absent
///   collector cannot affect app behavior (UDP is connectionless — datagrams
///   to nowhere are simply lost).
/// - Forwards the exact same sanitized text the ring buffer captures, so no
///   secrets leave the device. Each line is prefixed with the device's label
///   (`[nickname] …`) so one Mac-side `nc -lu <port>` can demux all devices.
public final class LogNetworkSink {
    public static let shared = LogNetworkSink()

    /// UserDefaults keys shared with the in-app config UI (App Info sheet).
    public static let hostDefaultsKey = "debug.logSink.host"
    public static let portDefaultsKey = "debug.logSink.port"
    public static let defaultPort = 9999
    /// Where the device label is read from (the app's chosen nickname).
    public static let nicknameDefaultsKey = "bitchat.nickname"

    private let queue = DispatchQueue(label: "chat.bitchat.securelogger.netsink", qos: .utility)
    private let defaults: UserDefaults
    private var label = ""
    private var enabled = false
    #if canImport(Network)
    private var connection: NWConnection?
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Re-read collector host/port and the device label from UserDefaults and
    /// (re)build the UDP connection. Call on launch and whenever the config UI
    /// changes. An empty host tears the sink down (no egress).
    public func reloadConfiguration() {
        let host = (defaults.string(forKey: Self.hostDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPort = defaults.integer(forKey: Self.portDefaultsKey)
        let port = storedPort > 0 ? storedPort : Self.defaultPort
        let label = (defaults.string(forKey: Self.nicknameDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        configure(host: host, port: port, label: label)
    }

    /// Point the sink at `host:port` with a device `label`. Empty host or an
    /// invalid port disables egress.
    public func configure(host: String, port: Int, label: String) {
        queue.async {
            self.label = label
            #if canImport(Network)
            self.connection?.cancel()
            self.connection = nil
            guard !host.isEmpty,
                  (1...65535).contains(port),
                  let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                self.enabled = false
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            connection.start(queue: self.queue)
            self.connection = connection
            self.enabled = true
            #else
            self.enabled = false
            #endif
        }
    }

    /// Forward one already-formatted, already-sanitized line. Non-blocking;
    /// drops silently when disabled or on any send failure.
    func send(_ line: String) {
        queue.async {
            guard self.enabled else { return }
            #if canImport(Network)
            guard let connection = self.connection else { return }
            let prefixed = self.label.isEmpty ? line : "[\(self.label)] \(line)"
            guard let data = (prefixed + "\n").data(using: .utf8) else { return }
            connection.send(content: data, completion: .idempotent)
            #endif
        }
    }
}
#endif
