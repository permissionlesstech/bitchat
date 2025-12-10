//
// RemoteCommand.swift
// Remote Terminal Protocol
//
// Defines commands that can be executed remotely on Mac from iPhone
//

import Foundation

/// Command to be executed on remote Mac
enum RemoteCommand: Codable, Equatable {
    /// Execute a shell command
    /// - Parameters:
    ///   - command: Shell command to execute (e.g., "ls -la", "npm run dev")
    ///   - workingDir: Working directory path (optional, defaults to home directory)
    case shell(command: String, workingDir: String?)

    /// Forward HTTP request to internet via Mac
    /// - Parameters:
    ///   - requestID: Unique request identifier
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - url: Target URL
    ///   - headers: HTTP headers
    ///   - body: Request body (optional)
    case httpProxy(requestID: UUID, method: String, url: String, headers: [String: String], body: Data?)

    /// Forward VPN packet (for Bluetooth VPN tunnel)
    /// - Parameters:
    ///   - data: Encoded VPNCommand data
    case vpnPacket(data: Data)

    /// Unique identifier for this command instance
    var id: UUID {
        UUID() // Generate fresh ID for each command
    }
}

// MARK: - Convenience Initializers

extension RemoteCommand {
    /// Create a shell command with default working directory
    static func shell(_ command: String) -> RemoteCommand {
        return .shell(command: command, workingDir: nil)
    }

    /// Create a shell command with specific working directory
    static func shell(_ command: String, in workingDir: String) -> RemoteCommand {
        return .shell(command: command, workingDir: workingDir)
    }
}

// MARK: - Description

extension RemoteCommand: CustomStringConvertible {
    var description: String {
        switch self {
        case .shell(let command, let workingDir):
            if let dir = workingDir {
                return "shell(cd \(dir) && \(command))"
            }
            return "shell(\(command))"
        case .httpProxy(let requestID, let method, let url, _, _):
            return "httpProxy(\(method) \(url) id:\(requestID.uuidString.prefix(8)))"
        case .vpnPacket(let data):
            return "vpnPacket(\(data.count) bytes)"
        }
    }
}

// MARK: - Example Usage
/*

 // Simple command
 let cmd1 = RemoteCommand.shell("ls -la")

 // Command with working directory
 let cmd2 = RemoteCommand.shell("npm run dev", workingDir: "/Users/user/dev/myproject")

 // Using convenience initializer
 let cmd3 = RemoteCommand.shell("git status", in: "~/dev/bitchat")

 // Claude Code example
 let claudeCommand = RemoteCommand.shell("""
 curl -X POST https://api.anthropic.com/v1/messages \\
   -H "x-api-key: $ANTHROPIC_API_KEY" \\
   -H "content-type: application/json" \\
   -d '{"model":"claude-3-5-sonnet-20241022","messages":[{"role":"user","content":"Write a hello world function"}]}'
 """)

 */
