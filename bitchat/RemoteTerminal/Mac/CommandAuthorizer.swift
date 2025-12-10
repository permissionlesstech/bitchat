//
// CommandAuthorizer.swift
// Remote Terminal - Mac Side
//
// Multi-level command authorization system with safety checks
//

import Foundation
import AppKit

/// Authorization result for command execution
enum AuthorizationResult {
    case allowed
    case needsApproval(reason: String)
    case blocked(reason: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Manages command authorization with safety checks
@MainActor
class CommandAuthorizer: ObservableObject {
    // MARK: - Published Properties

    @Published var pendingApprovals: [CommandApprovalRequest] = []

    // MARK: - Properties

    /// Commands that are always safe to execute
    private let safeCommands: Set<String> = [
        // Navigation
        "ls", "pwd", "cd", "tree",
        // Reading
        "cat", "less", "more", "head", "tail", "echo",
        // Search
        "grep", "find", "locate", "which", "whereis",
        // Info
        "whoami", "hostname", "date", "uptime", "uname",
        // Development
        "git", "npm", "node", "python", "python3", "pip", "pip3",
        "ruby", "gem", "cargo", "rustc", "swift", "go",
        // Network (read-only)
        "curl", "wget", "ping", "traceroute", "dig", "nslookup",
        // File info
        "file", "stat", "du", "df", "wc",
        // Version checks
        "xcodebuild", "brew",
        // File operations (safe)
        "touch", "mkdir", "open", "nano", "vim", "code",
        // macOS specific
        "defaults", "sw_vers", "system_profiler", "diskutil"
    ]

    /// Commands that require user approval
    private let dangerousCommands: Set<String> = [
        // File operations
        "rm", "rmdir", "mv", "cp",
        // Permissions
        "chmod", "chown", "chgrp",
        // System
        "sudo", "su", "kill", "killall", "pkill",
        "shutdown", "reboot", "halt", "poweroff",
        // Package management
        "brew install", "npm install", "pip install",
        // Process
        "launchctl", "systemctl", "service"
    ]

    /// Patterns that are always blocked
    private let blockedPatterns: [String] = [
        // Destructive filesystem
        "rm -rf /",
        "rm -rf ~",
        "rm -rf *",
        "> /dev/sda",
        "dd if=/dev/zero",
        "mkfs",
        // Fork bombs
        ":(){ :|:& };:",
        // System corruption
        "mv / ",
        "chmod -R 000",
        // Dangerous redirects
        "> /etc/",
        "> /usr/",
        "> /System/"
    ]

    // MARK: - Authorization

    /// Check if command is authorized to execute
    func authorize(_ command: String, from peerID: String) async -> AuthorizationResult {
        // First, check if device is authorized
        // TEMPORARY: Disabled for testing - any device can send commands
        // TODO: Re-enable after QR pairing flow is tested
        /*
        guard DeviceAuthorizationManager.shared.isAuthorized(peerID: peerID) else {
            return .blocked(reason: "Device not authorized. Pair device first.")
        }
        */

        // Check blocked patterns
        for pattern in blockedPatterns {
            if command.lowercased().contains(pattern.lowercased()) {
                return .blocked(reason: "Command contains dangerous pattern: '\(pattern)'")
            }
        }

        // Extract first word (command name)
        let components = command.split(separator: " ", maxSplits: 1)
        guard let commandName = components.first else {
            return .blocked(reason: "Empty command")
        }

        let cmd = String(commandName)
        let fullCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if user has whitelisted this exact command
        if isUserSafe(fullCommand) {
            return .allowed
        }

        // Check if it's a safe command
        if safeCommands.contains(cmd) {
            return .allowed
        }

        // Check for dangerous command combinations
        if fullCommand.contains("rm ") && (fullCommand.contains("-rf") || fullCommand.contains("-fr")) {
            return .needsApproval(reason: "Recursive deletion requires approval")
        }

        if fullCommand.hasPrefix("sudo ") {
            return .needsApproval(reason: "Elevated privileges require approval")
        }

        if dangerousCommands.contains(cmd) {
            return .needsApproval(reason: "Command '\(cmd)' requires approval")
        }

        // Check for installation commands (multi-word)
        for dangerous in dangerousCommands {
            if fullCommand.starts(with: dangerous) {
                return .needsApproval(reason: "Command '\(dangerous)' requires approval")
            }
        }

        // Unknown command - request approval for safety
        return .needsApproval(reason: "Unknown command requires approval")
    }

    /// Request user approval for command
    func requestApproval(for command: String, from peerID: String) async -> Bool {
        let request = CommandApprovalRequest(
            command: command,
            peerID: peerID,
            timestamp: Date()
        )

        // Add to pending list
        await MainActor.run {
            pendingApprovals.append(request)
        }

        // Show alert dialog
        return await showApprovalDialog(request)
    }

    // MARK: - User Interaction

    private func showApprovalDialog(_ request: CommandApprovalRequest) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Remote Command Approval Required"
                alert.informativeText = """
                iPhone wants to execute:

                \(request.command)

                From device: \(request.shortPeerID)

                Allow this command?
                """
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Deny")

                // Add "Always Allow" for safe-looking commands
                if !self.isDangerousCommand(request.command) {
                    alert.addButton(withTitle: "Always Allow This Command")
                }

                let response = alert.runModal()

                // Remove from pending
                self.pendingApprovals.removeAll { $0.id == request.id }

                switch response {
                case .alertFirstButtonReturn:
                    // Allow
                    continuation.resume(returning: true)
                case .alertThirdButtonReturn:
                    // Always allow - add to safe commands (persistent)
                    self.addToUserSafeList(request.command)
                    continuation.resume(returning: true)
                default:
                    // Deny
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func isDangerousCommand(_ command: String) -> Bool {
        let dangerous = ["rm", "sudo", "kill", "shutdown", "chmod", "mv /", "dd"]
        return dangerous.contains { command.contains($0) }
    }

    // MARK: - User Preferences

    /// Load user's custom safe commands
    private func loadUserSafeList() -> Set<String> {
        if let data = UserDefaults.standard.data(forKey: "RemoteTerminal.UserSafeCommands"),
           let commands = try? JSONDecoder().decode(Set<String>.self, from: data) {
            return commands
        }
        return []
    }

    /// Add command to user's safe list
    private func addToUserSafeList(_ command: String) {
        var safeList = loadUserSafeList()
        safeList.insert(command)

        if let data = try? JSONEncoder().encode(safeList) {
            UserDefaults.standard.set(data, forKey: "RemoteTerminal.UserSafeCommands")
            print("✅ Added to safe list: \(command)")
        }
    }

    /// Check if command is in user's safe list
    func isUserSafe(_ command: String) -> Bool {
        return loadUserSafeList().contains(command)
    }

    /// Clear user's safe list
    func clearUserSafeList() {
        UserDefaults.standard.removeObject(forKey: "RemoteTerminal.UserSafeCommands")
        print("🗑 Cleared user safe list")
    }
}

// MARK: - Supporting Types

struct CommandApprovalRequest: Identifiable {
    let id = UUID()
    let command: String
    let peerID: String
    let timestamp: Date

    var shortPeerID: String {
        String(peerID.prefix(16))
    }

    var isExpired: Bool {
        return Date().timeIntervalSince(timestamp) > 60 // 1 minute timeout
    }
}

// MARK: - Enhanced CommandHandler with Authorization

extension RemoteCommandHandler {
    /// Handle command with authorization checks
    func handleCommandSecure(_ command: RemoteCommand, from peerID: String, authorizer: CommandAuthorizer) async throws -> CommandResponse {
        // HTTP Proxy and VPN requests bypass authorization (always safe)
        if case .httpProxy = command {
            NSLog("🌐 [AUTHORIZATION] HTTP Proxy request - auto-approved")
            return try await handleCommand(command, from: peerID)
        }

        if case .vpnPacket = command {
            NSLog("📦 [AUTHORIZATION] VPN packet - auto-approved")
            return try await handleCommand(command, from: peerID)
        }

        // Extract command string for shell commands
        let commandString: String
        switch command {
        case .shell(let cmd, _):
            commandString = cmd
        case .httpProxy, .vpnPacket:
            fatalError("httpProxy/vpnPacket should be handled above")
        }

        // Check authorization
        let authResult = await authorizer.authorize(commandString, from: peerID)

        switch authResult {
        case .allowed:
            // Execute directly
            return try await handleCommand(command, from: peerID)

        case .needsApproval(let reason):
            // Request user approval
            let approved = await authorizer.requestApproval(for: commandString, from: peerID)

            if approved {
                return try await handleCommand(command, from: peerID)
            } else {
                return CommandResponse.failure(
                    error: "Command denied by user: \(reason)",
                    exitCode: 403
                )
            }

        case .blocked(let reason):
            // Blocked - never execute
            return CommandResponse.failure(
                error: "Command blocked: \(reason)",
                exitCode: 403
            )
        }
    }
}

// MARK: - Command Safety Analyzer

extension CommandAuthorizer {
    /// Analyze command for potential risks
    func analyzeCommand(_ command: String) -> CommandRiskAnalysis {
        var risks: [CommandRisk] = []

        // Check for destructive operations
        if command.contains("rm ") {
            if command.contains("-rf") || command.contains("-fr") {
                risks.append(.destructiveFilesystem)
            }
        }

        // Check for privilege escalation
        if command.hasPrefix("sudo ") || command.contains("su ") {
            risks.append(.privilegeEscalation)
        }

        // Check for network operations
        if command.contains("curl") || command.contains("wget") {
            if command.contains("|") || command.contains("sh") {
                risks.append(.remoteCodeExecution)
            }
        }

        // Check for redirection to sensitive paths
        let sensitivePaths = ["/etc/", "/usr/", "/System/", "/Library/"]
        for path in sensitivePaths {
            if command.contains("> \(path)") || command.contains(">> \(path)") {
                risks.append(.systemModification)
            }
        }

        // Check for process killing
        if command.contains("kill") && command.contains("-9") {
            risks.append(.processTermination)
        }

        // Determine overall risk level
        let riskLevel: RiskLevel
        if risks.isEmpty {
            riskLevel = .safe
        } else if risks.contains(.destructiveFilesystem) || risks.contains(.remoteCodeExecution) {
            riskLevel = .critical
        } else if risks.count > 1 {
            riskLevel = .high
        } else {
            riskLevel = .medium
        }

        return CommandRiskAnalysis(
            command: command,
            riskLevel: riskLevel,
            risks: risks
        )
    }
}

enum CommandRisk: String, CaseIterable {
    case destructiveFilesystem = "Destructive filesystem operation"
    case privilegeEscalation = "Privilege escalation"
    case remoteCodeExecution = "Remote code execution"
    case systemModification = "System file modification"
    case processTermination = "Process termination"
    case networkAccess = "Network access"

    var icon: String {
        switch self {
        case .destructiveFilesystem: return "⚠️"
        case .privilegeEscalation: return "🔐"
        case .remoteCodeExecution: return "🌐"
        case .systemModification: return "⚙️"
        case .processTermination: return "🛑"
        case .networkAccess: return "📡"
        }
    }
}

enum RiskLevel: Int, Comparable {
    case safe = 0
    case medium = 1
    case high = 2
    case critical = 3

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    var color: String {
        switch self {
        case .safe: return "green"
        case .medium: return "yellow"
        case .high: return "orange"
        case .critical: return "red"
        }
    }
}

struct CommandRiskAnalysis {
    let command: String
    let riskLevel: RiskLevel
    let risks: [CommandRisk]

    var requiresApproval: Bool {
        return riskLevel >= .medium
    }

    var shouldBlock: Bool {
        return riskLevel == .critical && risks.count > 2
    }

    var summary: String {
        if risks.isEmpty {
            return "Safe command"
        }
        let riskList = risks.map { "\($0.icon) \($0.rawValue)" }.joined(separator: ", ")
        return "Risk level: \(riskLevel.color.uppercased()) - \(riskList)"
    }
}
