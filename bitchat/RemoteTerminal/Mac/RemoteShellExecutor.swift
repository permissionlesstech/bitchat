//
// RemoteShellExecutor.swift
// Remote Terminal - Mac Side
//
// Executes shell commands received from iPhone
//

import Foundation
import Darwin

/// Executes shell commands on Mac
class RemoteShellExecutor {
    // MARK: - Properties

    /// Default working directory (user's home)
    private let defaultWorkingDirectory: URL

    /// Shell to use for execution
    private let shellPath: String

    /// Maximum output size (500KB) to prevent BLE overflow
    private let maxOutputSize: Int = 500_000

    /// Command timeout (60 seconds)
    private let timeout: TimeInterval = 60.0

    #if os(macOS)
    /// VPN packet forwarder (Mac only)
    private var packetForwarder: MacPacketForwarder?
    #endif

    // MARK: - Initialization

    init(
        defaultWorkingDirectory: URL? = nil,
        shellPath: String = "/bin/zsh"
    ) {
        self.shellPath = shellPath

        if let customDir = defaultWorkingDirectory {
            self.defaultWorkingDirectory = customDir
        } else {
            // Get real home directory using POSIX getpwuid (bypasses sandbox)
            var realHome = NSHomeDirectory() // Fallback

            let uid = getuid()
            if let pw = getpwuid(uid),
               let homeDir = pw.pointee.pw_dir {
                let homePath = String(cString: homeDir)
                if !homePath.contains("/Containers/") {
                    realHome = homePath
                }
            }

            self.defaultWorkingDirectory = URL(fileURLWithPath: realHome)
        }

        NSLog("🏠 [Mac-EXECUTOR] Initial working directory: \(self.defaultWorkingDirectory.path)")
    }

    #if os(macOS)
    /// Set VPN packet forwarder (Mac only)
    func setPacketForwarder(_ forwarder: MacPacketForwarder) {
        self.packetForwarder = forwarder
        NSLog("📦 [Mac-EXECUTOR] VPN packet forwarder configured")
    }
    #endif

    // MARK: - Public API

    /// Execute a remote command
    func execute(_ command: RemoteCommand) async throws -> CommandResponse {
        switch command {
        case .shell(let cmd, let workingDir):
            return try await executeShell(cmd, workingDir: workingDir)
        case .httpProxy(let requestID, let method, let url, let headers, let body):
            return try await executeHTTPProxy(requestID: requestID, method: method, url: url, headers: headers, body: body)
        case .vpnPacket(let data):
            return try await executeVPNPacket(data: data)
        }
    }

    // MARK: - VPN Packet Execution

    private func executeVPNPacket(data: Data) async throws -> CommandResponse {
        NSLog("📦 [Mac-VPN] Received VPN packet data (\(data.count) bytes)")

        // Decode VPN command
        guard let vpnCommand = try? JSONDecoder().decode(VPNCommand.self, from: data) else {
            return CommandResponse.failure(
                commandID: UUID(),
                error: "Failed to decode VPN command",
                exitCode: 1
            )
        }

        switch vpnCommand {
        case .forwardPacket(let packet):
            // Forward IP packet to internet
            NSLog("🌐 [Mac-VPN] Forwarding IP packet to internet")
            let parser = IPPacketParser(data: packet.ipPacketData)
            NSLog("🌐 [Mac-VPN] Packet: \(parser.description)")

            #if os(macOS)
            // Use MacPacketForwarder if available
            if let forwarder = packetForwarder {
                // We need a tunnel session - for now, create a pseudo-peer ID
                // In a full implementation, this should be passed from the command context
                let pseudoPeerID = PeerID(str: "vpn-peer")

                // Handle the incoming packet
                await forwarder.handleIncomingPacket(packet, from: pseudoPeerID)

                return CommandResponse.success(
                    commandID: UUID(),
                    output: "VPN packet forwarded to internet"
                )
            } else {
                NSLog("⚠️ [Mac-VPN] No packet forwarder configured")
                return CommandResponse.success(
                    commandID: UUID(),
                    output: "VPN packet received (forwarder not configured)"
                )
            }
            #else
            // iOS doesn't forward packets
            return CommandResponse.success(
                commandID: UUID(),
                output: "VPN packet received"
            )
            #endif

        case .startTunnel(let tunnelID):
            NSLog("🚀 [Mac-VPN] Start tunnel: \(tunnelID)")
            return CommandResponse.success(commandID: UUID(), output: "Tunnel started")

        case .stopTunnel(let tunnelID):
            NSLog("🛑 [Mac-VPN] Stop tunnel: \(tunnelID)")
            return CommandResponse.success(commandID: UUID(), output: "Tunnel stopped")

        case .ack(let packetID):
            NSLog("✅ [Mac-VPN] ACK: \(packetID)")
            return CommandResponse.success(commandID: UUID(), output: "ACK received")

        case .status(let isActive, let tunnelID):
            NSLog("📊 [Mac-VPN] Status: \(isActive ? "active" : "inactive"), tunnel: \(tunnelID)")
            return CommandResponse.success(commandID: UUID(), output: "Status: \(isActive)")
        }
    }

    // MARK: - Shell Execution

    private func executeShell(_ command: String, workingDir: String?) async throws -> CommandResponse {
        let commandID = UUID()

        // Determine working directory
        let workingDirURL: URL
        if let workingDir = workingDir {
            // Expand ~ to home directory
            let expandedPath = NSString(string: workingDir).expandingTildeInPath
            workingDirURL = URL(fileURLWithPath: expandedPath)
            NSLog("🗂 [Mac-EXECUTOR] Working dir: '\(workingDir)' -> '\(expandedPath)' -> '\(workingDirURL.path)'")
        } else {
            workingDirURL = defaultWorkingDirectory
            NSLog("🗂 [Mac-EXECUTOR] Using default working dir: '\(workingDirURL.path)'")
        }

        // Verify working directory exists
        guard FileManager.default.fileExists(atPath: workingDirURL.path) else {
            NSLog("❌ [Mac-EXECUTOR] Working directory does NOT exist: '\(workingDirURL.path)'")
            return CommandResponse.failure(
                commandID: commandID,
                error: "Working directory does not exist: \(workingDirURL.path)",
                exitCode: 1,
                workingDirectory: workingDirURL.path
            )
        }

        NSLog("✅ [Mac-EXECUTOR] Executing '\(command)' in '\(workingDirURL.path)'")

        // Check if this is a 'cd' command - if so, append '&& pwd' to get new directory
        let isChangeDirectory = command.trimmingCharacters(in: .whitespaces).hasPrefix("cd ")
        let actualCommand = isChangeDirectory ? "\(command) && pwd" : command

        // Create process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", actualCommand]
        process.currentDirectoryURL = workingDirURL

        // Set up pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Capture output asynchronously
        var stdoutData = Data()
        var stderrData = Data()

        outputPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                stdoutData.append(data)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                stderrData.append(data)
            }
        }

        // Execute with timeout
        do {
            try process.run()

            // Wait with timeout
            let startTime = Date()
            while process.isRunning {
                if Date().timeIntervalSince(startTime) > timeout {
                    process.terminate()
                    return CommandResponse.failure(
                        commandID: commandID,
                        error: "Command timed out after \(timeout) seconds",
                        exitCode: 124, // Standard timeout exit code
                        workingDirectory: workingDirURL.path
                    )
                }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            process.waitUntilExit()

            // Close handlers
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            // Read any remaining data
            stdoutData.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            stderrData.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

            // Convert to strings
            var stdout = String(data: stdoutData, encoding: .utf8)
            var stderr = String(data: stderrData, encoding: .utf8)

            // For 'cd' commands, extract new directory from output (last line should be pwd result)
            var newWorkingDirectory = workingDirURL.path
            if isChangeDirectory, let stdoutStr = stdout, !stdoutStr.isEmpty {
                // The output should be the new directory from 'pwd'
                let lines = stdoutStr.split(separator: "\n", omittingEmptySubsequences: true)
                if let lastLine = lines.last {
                    newWorkingDirectory = String(lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Remove the pwd output from stdout so user doesn't see it
                    if lines.count > 1 {
                        stdout = lines.dropLast().joined(separator: "\n")
                    } else {
                        stdout = "" // Only pwd output, hide it
                    }
                }
            }

            // Truncate if too large
            if let stdoutStr = stdout, stdoutStr.count > maxOutputSize {
                let truncated = String(stdoutStr.prefix(maxOutputSize))
                stdout = truncated + "\n\n... (output truncated, \(stdoutStr.count - maxOutputSize) bytes omitted)"
            }

            if let stderrStr = stderr, stderrStr.count > maxOutputSize {
                let truncated = String(stderrStr.prefix(maxOutputSize))
                stderr = truncated + "\n\n... (output truncated, \(stderrStr.count - maxOutputSize) bytes omitted)"
            }

            // Create response
            return CommandResponse.fromProcess(
                commandID: commandID,
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                workingDirectory: newWorkingDirectory
            )

        } catch {
            return CommandResponse.failure(
                commandID: commandID,
                error: "Failed to execute command: \(error.localizedDescription)",
                exitCode: 1,
                workingDirectory: workingDirURL.path
            )
        }
    }

    // MARK: - HTTP Proxy Execution

    private func executeHTTPProxy(
        requestID: UUID,
        method: String,
        url: String,
        headers: [String: String],
        body: Data?
    ) async throws -> CommandResponse {
        NSLog("🌐 [Mac-HTTP-PROXY] Forwarding \(method) \(url)")

        guard let requestURL = URL(string: url) else {
            return CommandResponse(
                commandID: requestID,
                success: false,
                output: nil,
                error: "Invalid URL: \(url)",
                exitCode: 400,
                data: nil
            )
        }

        // Create URLRequest
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = method
        urlRequest.timeoutInterval = 30

        // Set headers
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // Set body
        if let body = body {
            urlRequest.httpBody = body
        }

        do {
            // Execute HTTP request
            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                return CommandResponse(
                    commandID: requestID,
                    success: false,
                    output: nil,
                    error: "Invalid HTTP response",
                    exitCode: 500,
                    data: nil
                )
            }

            let statusCode = httpResponse.statusCode
            let isSuccess = (200..<300).contains(statusCode)

            NSLog("🌐 [Mac-HTTP-PROXY] Response: \(statusCode) (\(data.count) bytes)")

            // Build response headers string for output
            var headersString = "HTTP/\(httpResponse.value(forHTTPHeaderField: "version") ?? "1.1") \(statusCode)\n"
            for (key, value) in httpResponse.allHeaderFields {
                headersString += "\(key): \(value)\n"
            }

            return CommandResponse(
                commandID: requestID,
                success: isSuccess,
                output: headersString,
                error: isSuccess ? nil : "HTTP \(statusCode)",
                exitCode: Int32(statusCode),
                data: data
            )

        } catch {
            NSLog("❌ [Mac-HTTP-PROXY] Error: \(error.localizedDescription)")
            return CommandResponse(
                commandID: requestID,
                success: false,
                output: nil,
                error: "HTTP request failed: \(error.localizedDescription)",
                exitCode: 500,
                data: nil
            )
        }
    }
}

// MARK: - Error Types

enum RemoteExecutorError: LocalizedError {
    case invalidWorkingDirectory(String)
    case executionFailed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidWorkingDirectory(let path):
            return "Invalid working directory: \(path)"
        case .executionFailed(let message):
            return "Execution failed: \(message)"
        case .timeout:
            return "Command execution timed out"
        }
    }
}

// MARK: - Example Usage
/*

 // Create executor
 let executor = RemoteShellExecutor()

 // Execute simple command
 let cmd1 = RemoteCommand.shell("ls -la")
 let response1 = try await executor.execute(cmd1)
 print(response1.displayOutput)

 // Execute in specific directory
 let cmd2 = RemoteCommand.shell("npm run dev", workingDir: "~/dev/myproject")
 let response2 = try await executor.execute(cmd2)

 // Execute Claude Code command
 let claudeCmd = RemoteCommand.shell("""
 curl -X POST https://api.anthropic.com/v1/messages \\
   -H "x-api-key: $ANTHROPIC_API_KEY" \\
   -H "content-type: application/json" \\
   -d '{"model":"claude-3-5-sonnet-20241022","messages":[{"role":"user","content":"Hello"}]}'
 """)
 let claudeResponse = try await executor.execute(claudeCmd)
 print(claudeResponse.displayOutput) // Shows Claude's JSON response

 */
