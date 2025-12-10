//
// CommandHandler.swift
// Remote Terminal - Mac Side
//
// Integrates RemoteShellExecutor with BitChat messaging
//

import Foundation

/// Handles incoming remote commands from BitChat
class RemoteCommandHandler {
    // MARK: - Properties

    private let executor: RemoteShellExecutor
    private var authorizedPeers: Set<String> = []

    // MARK: - Initialization

    init(executor: RemoteShellExecutor = RemoteShellExecutor()) {
        self.executor = executor
        loadAuthorizedPeers()
    }

    // MARK: - Public API

    /// Get the executor instance (for VPN configuration)
    func getExecutor() -> RemoteShellExecutor {
        return executor
    }

    /// Handle incoming command from iPhone
    /// - Parameters:
    ///   - command: RemoteCommand to execute
    ///   - peerID: PeerID of sender (iPhone)
    /// - Returns: CommandResponse with execution result
    func handleCommand(_ command: RemoteCommand, from peerID: String) async throws -> CommandResponse {
        // Authorization is checked in CommandAuthorizer.authorize()
        // DeviceAuthorizationManager handles device authorization via QR pairing

        // Execute command
        do {
            let response = try await executor.execute(command)
            logCommand(command, from: peerID, response: response)
            return response
        } catch {
            let errorResponse = CommandResponse.failure(
                error: "Execution error: \(error.localizedDescription)",
                exitCode: 1
            )
            logCommand(command, from: peerID, response: errorResponse)
            return errorResponse
        }
    }

    /// Check if peer is authorized
    func isAuthorized(_ peerID: String) -> Bool {
        return authorizedPeers.contains(peerID)
    }

    /// Manually authorize a peer
    func authorize(_ peerID: String) {
        authorizedPeers.insert(peerID)
        saveAuthorizedPeers()
    }

    /// Revoke authorization
    func deauthorize(_ peerID: String) {
        authorizedPeers.remove(peerID)
        saveAuthorizedPeers()
    }

    // MARK: - Authorization

    private func requestAuthorization(from peerID: String) async throws -> Bool {
        // TODO: Show macOS notification or alert
        // For MVP, auto-approve for testing
        print("⚠️ Authorization request from peer: \(peerID)")
        print("✅ Auto-approved (MVP mode - implement user prompt later)")
        return true

        // Production code would look like:
        /*
        let alert = NSAlert()
        alert.messageText = "Remote Terminal Access Request"
        alert.informativeText = "iPhone wants to execute commands on this Mac"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        let response = await alert.beginSheetModal(for: NSApp.mainWindow)
        return response == .alertFirstButtonReturn
        */
    }

    // MARK: - Persistence

    private func loadAuthorizedPeers() {
        if let data = UserDefaults.standard.data(forKey: "RemoteTerminal.AuthorizedPeers"),
           let peers = try? JSONDecoder().decode(Set<String>.self, from: data) {
            authorizedPeers = peers
        }
    }

    private func saveAuthorizedPeers() {
        if let data = try? JSONEncoder().encode(authorizedPeers) {
            UserDefaults.standard.set(data, forKey: "RemoteTerminal.AuthorizedPeers")
        }
    }

    // MARK: - Logging

    private func logCommand(_ command: RemoteCommand, from peerID: String, response: CommandResponse) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let status = response.success ? "✅" : "❌"
        let log = "[\(timestamp)] \(status) Peer: \(peerID) | Command: \(command.description) | Exit: \(response.exitCode)"

        print(log)

        // Also write to file for audit trail
        writeToAuditLog(log)
    }

    private func writeToAuditLog(_ entry: String) {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("BitChat")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logFile = logDir.appendingPathComponent("remote-terminal.log")

        // Append to log
        if let data = (entry + "\n").data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFile) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
}

// MARK: - Integration with BitChat
/*

 // In your ChatViewModel.swift or MessageRouter.swift:

 class ChatViewModel {
     private let commandHandler = RemoteCommandHandler()

     func handleRemoteCommand(_ commandData: Data, from peerID: PeerID) async {
         do {
             // Decode command
             let command = try JSONDecoder().decode(RemoteCommand.self, from: commandData)

             // Execute
             let response = try await commandHandler.handleCommand(command, from: peerID.id)

             // Send response back
             let responseData = try JSONEncoder().encode(response)
             sendPrivateMessage(responseData, to: peerID)

         } catch {
             print("Error handling remote command: \(error)")
         }
     }
 }

 */
