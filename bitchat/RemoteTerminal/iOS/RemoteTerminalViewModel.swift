//
// RemoteTerminalViewModel.swift
// Remote Terminal - iOS Side
//
// Business logic for remote terminal
//

#if os(iOS)
import Foundation
import Combine
import Network

/// ViewModel for RemoteTerminalView
@MainActor
class RemoteTerminalViewModel: ObservableObject {
    // MARK: - Published State

    /// Terminal output lines (command + response history)
    @Published var outputLines: [TerminalLine] = []

    /// Current command being typed
    @Published var currentCommand: String = ""

    /// Whether a command is currently executing
    @Published var isExecuting: Bool = false

    /// Current working directory on remote Mac
    @Published var workingDirectory: String = "~"

    /// Connection status to Mac
    @Published var isConnected: Bool = false

    /// Selected Mac peer ID (must be set before use)
    var macPeerID: String?

    /// HTTP Proxy enabled (internet via Bluetooth)
    @Published var isProxyEnabled: Bool = false

    // MARK: - Dependencies

    /// MessageRouter for sending commands (injected from ChatViewModel)
    var messageRouter: MessageRouter?

    /// HTTP Proxy listener (Network.framework)
    private var proxyListener: NWListener?

    /// Active proxy connections
    private var proxyConnections: [NWConnection] = []

    /// Command history for up/down arrow navigation
    private var commandHistory: [String] = []
    private var historyIndex: Int = 0

    // MARK: - Initialization

    init(messageRouter: MessageRouter? = nil) {
        self.messageRouter = messageRouter
        self.outputLines = [
            TerminalLine(text: "BitChat Remote Terminal v1.0", type: .system),
            TerminalLine(text: "Connected to Mac. Type commands below.", type: .system),
            TerminalLine(text: "", type: .system)
        ]
    }

    // MARK: - Proxy Control

    /// Toggle HTTP proxy on/off
    func toggleProxy() async {
        if isProxyEnabled {
            stopProxy()
        } else {
            await startProxy()
        }
    }

    /// Start HTTP proxy server
    private func startProxy() async {
        guard messageRouter != nil, macPeerID != nil else {
            addOutput("Error: No Mac connected", type: .error)
            return
        }

        do {
            // Create TCP listener on port 8080
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(using: parameters, on: 8080)

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    await self?.handleProxyConnection(connection)
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isProxyEnabled = true
                        self?.addOutput("✅ Bluetooth Internet enabled on port 8080", type: .system)
                        self?.addOutput("   Configure WiFi Proxy: localhost:8080", type: .system)
                        NSLog("✅ [HTTP-PROXY] Listener ready on port 8080")
                    case .failed(let error):
                        self?.isProxyEnabled = false
                        self?.addOutput("❌ Proxy failed: \(error.localizedDescription)", type: .error)
                        NSLog("❌ [HTTP-PROXY] Listener failed: \(error)")
                    case .cancelled:
                        self?.isProxyEnabled = false
                        NSLog("🛑 [HTTP-PROXY] Listener cancelled")
                    default:
                        break
                    }
                }
            }

            listener.start(queue: .main)
            self.proxyListener = listener

        } catch {
            addOutput("❌ Failed to start proxy: \(error.localizedDescription)", type: .error)
            isProxyEnabled = false
        }
    }

    /// Stop HTTP proxy server
    private func stopProxy() {
        proxyListener?.cancel()
        proxyListener = nil

        for connection in proxyConnections {
            connection.cancel()
        }
        proxyConnections.removeAll()

        isProxyEnabled = false
        addOutput("🛑 Bluetooth Internet disabled", type: .system)
    }

    /// Handle incoming proxy connection
    private func handleProxyConnection(_ connection: NWConnection) async {
        proxyConnections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state {
                    NSLog("🔗 [HTTP-PROXY] New connection")
                    await self?.receiveProxyRequest(from: connection)
                }
            }
        }

        connection.start(queue: .main)
    }

    /// Receive and forward HTTP request
    private func receiveProxyRequest(from connection: NWConnection) async {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                if let error = error {
                    NSLog("❌ [HTTP-PROXY] Receive error: \(error)")
                    return
                }

                guard let data = data, !data.isEmpty else {
                    if isComplete {
                        connection.cancel()
                    }
                    return
                }

                NSLog("📥 [HTTP-PROXY] Received \(data.count) bytes")

                // Parse HTTP request
                guard let requestString = String(data: data, encoding: .utf8) else {
                    NSLog("❌ [HTTP-PROXY] Failed to parse request")
                    self.sendProxyError(to: connection, message: "Invalid request encoding")
                    return
                }

                NSLog("📄 [HTTP-PROXY] Request:\n\(requestString.prefix(500))")

                // Parse request line
                let lines = requestString.components(separatedBy: "\r\n")
                guard let requestLine = lines.first else {
                    self.sendProxyError(to: connection, message: "No request line")
                    return
                }

                let parts = requestLine.components(separatedBy: " ")
                guard parts.count >= 3 else {
                    self.sendProxyError(to: connection, message: "Invalid request line")
                    return
                }

                let method = parts[0]
                let url = parts[1]

                // Parse headers
                var headers: [String: String] = [:]
                var bodyStartIndex = 0
                for (index, line) in lines.enumerated() {
                    if line.isEmpty {
                        bodyStartIndex = index + 1
                        break
                    }
                    if index > 0 {
                        let headerParts = line.components(separatedBy: ": ")
                        if headerParts.count == 2 {
                            headers[headerParts[0]] = headerParts[1]
                        }
                    }
                }

                // Extract body
                var bodyData: Data? = nil
                if bodyStartIndex < lines.count {
                    let bodyLines = lines[bodyStartIndex...]
                    let bodyString = bodyLines.joined(separator: "\r\n")
                    bodyData = bodyString.data(using: .utf8)
                }

                // Construct full URL
                let fullURL: String
                if url.hasPrefix("http://") || url.hasPrefix("https://") {
                    fullURL = url
                } else if let host = headers["Host"] {
                    fullURL = "http://\(host)\(url)"
                } else {
                    self.sendProxyError(to: connection, message: "No Host header")
                    return
                }

                NSLog("🌐 [HTTP-PROXY] Forwarding: \(method) \(fullURL)")

                // Forward to Mac via Bluetooth
                await self.forwardHTTPRequest(
                    method: method,
                    url: fullURL,
                    headers: headers,
                    body: bodyData,
                    to: connection
                )
            }
        }
    }

    /// Forward HTTP request to Mac via Bluetooth
    private func forwardHTTPRequest(
        method: String,
        url: String,
        headers: [String: String],
        body: Data?,
        to connection: NWConnection
    ) async {
        guard let messageRouter = messageRouter,
              let macPeerID = macPeerID else {
            NSLog("❌ [HTTP-PROXY] No Mac connection")
            sendProxyError(to: connection, message: "Mac not connected")
            return
        }

        let requestID = UUID()
        let command = RemoteCommand.httpProxy(
            requestID: requestID,
            method: method,
            url: url,
            headers: headers,
            body: body
        )

        do {
            // Send via Bluetooth
            let peer = PeerID(str: macPeerID)
            let response = try await messageRouter.sendRemoteCommand(command, to: peer)

            NSLog("📥 [HTTP-PROXY] Mac response: \(response.exitCode) (\(response.data?.count ?? 0) bytes)")

            // Build HTTP response
            let statusCode = Int(response.exitCode)
            let statusText = self.httpStatusText(for: statusCode)

            var httpResponse = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

            // Add headers
            if let data = response.data {
                httpResponse += "Content-Length: \(data.count)\r\n"
                httpResponse += "Connection: close\r\n"
                httpResponse += "\r\n"

                // Send headers + body
                if let headerData = httpResponse.data(using: .utf8) {
                    var fullResponse = headerData
                    fullResponse.append(data)

                    connection.send(content: fullResponse, completion: .contentProcessed { sendError in
                        if let sendError = sendError {
                            NSLog("❌ [HTTP-PROXY] Send error: \(sendError)")
                        }
                        connection.cancel()
                    })
                }
            } else {
                httpResponse += "Content-Length: 0\r\n"
                httpResponse += "Connection: close\r\n"
                httpResponse += "\r\n"

                if let responseData = httpResponse.data(using: .utf8) {
                    connection.send(content: responseData, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            }

        } catch {
            NSLog("❌ [HTTP-PROXY] Forward error: \(error)")
            sendProxyError(to: connection, message: "Bluetooth forward failed: \(error.localizedDescription)")
        }
    }

    /// Send HTTP error response
    private func sendProxyError(to connection: NWConnection, message: String) {
        let response = """
        HTTP/1.1 502 Bad Gateway\r
        Content-Type: text/plain\r
        Content-Length: \(message.count)\r
        Connection: close\r
        \r
        \(message)
        """

        if let data = response.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// HTTP status text
    private func httpStatusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }

    // MARK: - Public Actions

    /// Execute current command
    func executeCommand() {
        guard !currentCommand.isEmpty else { return }
        guard let macPeerID = macPeerID else {
            addOutput("Error: No Mac connected", type: .error)
            return
        }

        // Add command to output
        let prompt = "\(workingDirectory) $ "
        addOutput(prompt + currentCommand, type: .command)

        // Save to history
        commandHistory.append(currentCommand)
        historyIndex = commandHistory.count

        // Send command
        let command = RemoteCommand.shell(command: currentCommand, workingDir: workingDirectory)
        isExecuting = true

        NSLog("📤 [iOS-TERMINAL] Sending command: '\(currentCommand)' in directory: '\(workingDirectory)'")

        Task {
            do {
                // Send via BitChat (implementation depends on integration)
                let response = try await sendCommand(command, to: macPeerID)
                NSLog("📥 [iOS-TERMINAL] Received response: success=\(response.success), exitCode=\(response.exitCode)")

                // Display response
                if let output = response.output, !output.isEmpty {
                    addOutput(output, type: .output)
                }

                if let error = response.error, !error.isEmpty {
                    addOutput(error, type: .error)
                }

                // Update working directory if command was 'cd'
                if currentCommand.starts(with: "cd "), let newDir = response.workingDirectory {
                    NSLog("📂 [iOS-TERMINAL] Updated working directory: '\(workingDirectory)' -> '\(newDir)'")
                    workingDirectory = newDir
                }

                isExecuting = false
                currentCommand = ""

            } catch {
                addOutput("Error: \(error.localizedDescription)", type: .error)
                isExecuting = false
            }
        }
    }

    /// Navigate command history (up/down arrows)
    func navigateHistory(direction: HistoryDirection) {
        guard !commandHistory.isEmpty else { return }

        switch direction {
        case .up:
            if historyIndex > 0 {
                historyIndex -= 1
                currentCommand = commandHistory[historyIndex]
            }
        case .down:
            if historyIndex < commandHistory.count - 1 {
                historyIndex += 1
                currentCommand = commandHistory[historyIndex]
            } else {
                historyIndex = commandHistory.count
                currentCommand = ""
            }
        }
    }

    /// Clear terminal output
    func clearTerminal() {
        outputLines = []
        addOutput("Terminal cleared", type: .system)
    }

    /// Send Ctrl+C to interrupt running command
    func sendInterrupt() {
        // TODO: Implement process interruption
        addOutput("^C", type: .system)
        isExecuting = false
    }

    // MARK: - Private Helpers

    private func addOutput(_ text: String, type: TerminalLineType) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            outputLines.append(TerminalLine(text: String(line), type: type))
        }
    }

    private func sendCommand(_ command: RemoteCommand, to peerID: String) async throws -> CommandResponse {
        guard let messageRouter = messageRouter else {
            throw RemoteCommandError.executionFailed("MessageRouter not available")
        }

        NSLog("📤 [RemoteTerminal] Sending command to \(peerID.prefix(8)): \(command)")

        // Convert peerID string to PeerID
        let peer = PeerID(str: peerID)

        // Send command via MessageRouter
        let response = try await messageRouter.sendRemoteCommand(command, to: peer)

        NSLog("✅ [RemoteTerminal] Received response from \(peerID.prefix(8)): success=\(response.success), exitCode=\(response.exitCode)")

        return response
    }
}

// MARK: - Supporting Types

/// Terminal output line
struct TerminalLine: Identifiable {
    let id = UUID()
    let text: String
    let type: TerminalLineType
    let timestamp = Date()
}

/// Terminal line type (for styling)
enum TerminalLineType {
    case command   // User input
    case output    // stdout
    case error     // stderr
    case system    // System messages
}

/// History navigation direction
enum HistoryDirection {
    case up
    case down
}

/// Errors
enum TerminalError: LocalizedError {
    case noMessagingService
    case notConnected
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMessagingService:
            return "Messaging service not configured"
        case .notConnected:
            return "Not connected to Mac"
        case .commandFailed(let msg):
            return "Command failed: \(msg)"
        }
    }
}

// MARK: - Messaging Protocol

/// Protocol for sending commands via BitChat
protocol RemoteCommandMessagingProtocol {
    func sendCommand(_ command: RemoteCommand, to peerID: String) async throws -> CommandResponse
}

// MARK: - Example Usage
/*

 // Create view model
 let viewModel = RemoteTerminalViewModel()
 viewModel.macPeerID = "abc123..."

 // Execute command
 viewModel.currentCommand = "ls -la"
 viewModel.executeCommand()

 // Navigate history
 viewModel.navigateHistory(direction: .up)

 // Clear
 viewModel.clearTerminal()

 */

#endif // os(iOS)
