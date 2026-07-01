// Standalone harness: does Apple's URLSession honor connectionProxyDictionary
// SOCKS settings for a plain HTTPS GET and for URLSessionWebSocketTask?
//
// Build:  swiftc -O proxy_probe.swift -o proxy_probe
// Usage:  proxy_probe <http|ws> <cf|raw> <proxyPort> [targetURL]
//
// Prints a single RESULT line: RESULT <mode> <keyStyle> <outcome> <detail>
// The caller correlates this with the SOCKS proxy's connection log to decide
// whether the request was proxied.
#if canImport(CFNetwork)
import CFNetwork
#endif
import Foundation

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: proxy_probe <http|ws> <cf|raw> <proxyPort> [targetURL]\n".utf8))
    exit(2)
}
let mode = args[1]
let keyStyle = args[2]
let proxyPort = Int(args[3]) ?? 19999
let host = "127.0.0.1"

func makeProxyDict() -> [AnyHashable: Any] {
    switch keyStyle {
#if os(macOS)
    case "cf":
        // The exact constants the app uses on macOS.
        return [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: host,
            kCFNetworkProxiesSOCKSPort as String: proxyPort
        ]
#endif
    default:
        // The exact raw string keys the app uses on iOS.
        return [
            "SOCKSEnable": 1,
            "SOCKSProxy": host,
            "SOCKSPort": proxyPort
        ]
    }
}

let cfg = URLSessionConfiguration.ephemeral
cfg.waitsForConnectivity = false
cfg.timeoutIntervalForRequest = 20
cfg.connectionProxyDictionary = makeProxyDict()
let session = URLSession(configuration: cfg)

func emit(_ outcome: String, _ detail: String) {
    print("RESULT \(mode) \(keyStyle) \(outcome) \(detail)")
    exit(outcome == "ERROR" ? 1 : 0)
}

let sem = DispatchSemaphore(value: 0)

if mode == "http" {
    let target = URL(string: args.count >= 5 ? args[4] : "https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv")!
    let task = session.dataTask(with: target) { data, resp, err in
        if let err = err {
            emit("ERROR", "\(err.localizedDescription)")
        } else if let http = resp as? HTTPURLResponse {
            emit("OK", "status=\(http.statusCode) bytes=\(data?.count ?? 0)")
        } else {
            emit("OK", "bytes=\(data?.count ?? 0)")
        }
    }
    task.resume()
} else {
    // WebSocket
    let target = URL(string: args.count >= 5 ? args[4] : "wss://relay.damus.io")!
    let ws = session.webSocketTask(with: target)
    ws.resume()
    // A successful ping proves the TLS+WS handshake completed end-to-end.
    ws.sendPing { err in
        if let err = err {
            emit("ERROR", "\(err.localizedDescription)")
        } else {
            emit("OK", "ws-ping-ok")
        }
    }
}

// Global watchdog so we never hang.
DispatchQueue.global().asyncAfter(deadline: .now() + 25) {
    emit("ERROR", "timeout")
}
sem.wait()
