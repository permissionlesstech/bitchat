//
// SessionManager.swift
// Remote Terminal - Shared
//
// Manages terminal sessions with isolation, timeout, and rate limiting
//

import Foundation

/// Manages remote terminal sessions
@MainActor
class SessionManager: ObservableObject {
    // MARK: - Singleton

    static let shared = SessionManager()

    // MARK: - Published Properties

    @Published var activeSessions: [String: TerminalSession] = [:]

    // MARK: - Properties

    private let sessionTimeout: TimeInterval = 300 // 5 minutes
    private let maxSessionsPerPeer = 3
    private let maxCommandsPerMinute = 30
    private let maxFailedAttemptsBeforeLock = 5

    private var cleanupTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        startPeriodicCleanup()
    }

    // MARK: - Session Lifecycle

    /// Create or resume session
    func getOrCreateSession(for peerID: String) -> TerminalSession {
        // Check if session exists and is valid
        if let existing = activeSessions[peerID], !existing.isExpired {
            // Update last activity
            activeSessions[peerID]?.lastActivity = Date()
            return existing
        }

        // Check session limit for this peer
        let peerSessions = activeSessions.values.filter { $0.peerID == peerID }
        if peerSessions.count >= maxSessionsPerPeer {
            // Remove oldest session
            if let oldest = peerSessions.min(by: { $0.lastActivity < $1.lastActivity }) {
                terminateSession(oldest.sessionID)
            }
        }

        // Create new session
        let session = TerminalSession(
            sessionID: UUID(),
            peerID: peerID,
            createdAt: Date(),
            lastActivity: Date(),
            timeout: sessionTimeout
        )

        activeSessions[session.id] = session

        print("🔐 Created session \(session.id) for peer \(peerID.prefix(16))...")

        return session
    }

    /// Update session activity
    func updateActivity(sessionID: UUID) {
        activeSessions[sessionID.uuidString]?.lastActivity = Date()
    }

    /// Record command execution
    func recordCommand(sessionID: UUID, success: Bool) {
        guard let session = activeSessions[sessionID.uuidString] else { return }

        activeSessions[sessionID.uuidString]?.commandCount += 1

        if !success {
            activeSessions[sessionID.uuidString]?.failedAttempts += 1

            // Lock session if too many failures
            if session.failedAttempts >= maxFailedAttemptsBeforeLock {
                lockSession(sessionID, reason: "Too many failed commands")
            }
        } else {
            // Reset failed attempts on success
            activeSessions[sessionID.uuidString]?.failedAttempts = 0
        }
    }

    /// Check rate limiting
    func checkRateLimit(sessionID: UUID) -> Bool {
        guard let session = activeSessions[sessionID.uuidString] else { return false }

        let oneMinuteAgo = Date().addingTimeInterval(-60)
        let recentCommands = session.commandHistory.filter { $0.timestamp > oneMinuteAgo }

        if recentCommands.count >= maxCommandsPerMinute {
            print("⚠️ Rate limit exceeded for session \(sessionID)")
            return false
        }

        return true
    }

    /// Lock session
    func lockSession(_ sessionID: UUID, reason: String) {
        activeSessions[sessionID.uuidString]?.isLocked = true
        activeSessions[sessionID.uuidString]?.lockReason = reason

        print("🔒 Locked session \(sessionID): \(reason)")
    }

    /// Unlock session
    func unlockSession(_ sessionID: UUID) {
        activeSessions[sessionID.uuidString]?.isLocked = false
        activeSessions[sessionID.uuidString]?.lockReason = nil
        activeSessions[sessionID.uuidString]?.failedAttempts = 0

        print("🔓 Unlocked session \(sessionID)")
    }

    /// Terminate session
    func terminateSession(_ sessionID: UUID) {
        if let session = activeSessions.removeValue(forKey: sessionID.uuidString) {
            print("🔚 Terminated session \(sessionID) for peer \(session.peerID.prefix(16))...")
        }
    }

    /// Terminate all sessions for peer
    func terminateAllSessions(for peerID: String) {
        let sessions = activeSessions.values.filter { $0.peerID == peerID }
        for session in sessions {
            terminateSession(session.sessionID)
        }
    }

    /// Get session statistics
    func getSessionStats(_ sessionID: UUID) -> SessionStatistics? {
        guard let session = activeSessions[sessionID.uuidString] else { return nil }

        let duration = Date().timeIntervalSince(session.createdAt)
        let avgCommandsPerMinute = Double(session.commandCount) / (duration / 60.0)

        return SessionStatistics(
            sessionID: sessionID,
            duration: duration,
            commandCount: session.commandCount,
            failedAttempts: session.failedAttempts,
            averageCommandsPerMinute: avgCommandsPerMinute
        )
    }

    // MARK: - Cleanup

    private func startPeriodicCleanup() {
        cleanupTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute

                await cleanupExpiredSessions()
            }
        }
    }

    private func cleanupExpiredSessions() {
        let expired = activeSessions.values.filter { $0.isExpired }

        for session in expired {
            terminateSession(session.sessionID)
        }

        if !expired.isEmpty {
            print("🧹 Cleaned up \(expired.count) expired session(s)")
        }
    }

    deinit {
        cleanupTask?.cancel()
    }
}

// MARK: - Terminal Session Model

struct TerminalSession: Identifiable {
    let sessionID: UUID
    let peerID: String
    let createdAt: Date
    var lastActivity: Date
    let timeout: TimeInterval

    var commandCount: Int = 0
    var failedAttempts: Int = 0
    var commandHistory: [CommandRecord] = []

    var isLocked: Bool = false
    var lockReason: String?

    var id: String { sessionID.uuidString }

    var isExpired: Bool {
        return Date().timeIntervalSince(lastActivity) > timeout
    }

    var remainingTime: TimeInterval {
        let elapsed = Date().timeIntervalSince(lastActivity)
        return max(0, timeout - elapsed)
    }

    var sessionDuration: TimeInterval {
        return Date().timeIntervalSince(createdAt)
    }

    mutating func addCommand(_ command: String, success: Bool) {
        let record = CommandRecord(
            command: command,
            timestamp: Date(),
            success: success
        )
        commandHistory.append(record)

        // Keep only last 100 commands
        if commandHistory.count > 100 {
            commandHistory.removeFirst(commandHistory.count - 100)
        }
    }
}

struct CommandRecord {
    let command: String
    let timestamp: Date
    let success: Bool
}

struct SessionStatistics {
    let sessionID: UUID
    let duration: TimeInterval
    let commandCount: Int
    let failedAttempts: Int
    let averageCommandsPerMinute: Double

    var successRate: Double {
        guard commandCount > 0 else { return 0 }
        return Double(commandCount - failedAttempts) / Double(commandCount)
    }
}

// MARK: - Session Monitoring

extension SessionManager {
    /// Get all active sessions
    func getAllSessions() -> [TerminalSession] {
        return Array(activeSessions.values).sorted { $0.createdAt > $1.createdAt }
    }

    /// Get sessions for specific peer
    func getSessions(for peerID: String) -> [TerminalSession] {
        return activeSessions.values.filter { $0.peerID == peerID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Get total active session count
    var activeSessionCount: Int {
        return activeSessions.count
    }

    /// Get locked session count
    var lockedSessionCount: Int {
        return activeSessions.values.filter { $0.isLocked }.count
    }
}

// MARK: - SwiftUI Views

#if os(macOS)
import SwiftUI

/// View for monitoring active sessions
struct SessionMonitorView: View {
    @StateObject private var sessionManager = SessionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Active Sessions")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Text("\(sessionManager.activeSessionCount) active")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Session list
            if sessionManager.activeSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "circle.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("No active sessions")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sessionManager.getAllSessions()) { session in
                            SessionRowView(session: session)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct SessionRowView: View {
    let session: TerminalSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Status indicator
                Circle()
                    .fill(session.isLocked ? Color.red : Color.green)
                    .frame(width: 12, height: 12)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Session \(session.sessionID.uuidString.prefix(8))...")
                        .font(.headline)

                    Text("Peer: \(session.peerID.prefix(16))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(session.commandCount) commands")
                        .font(.caption)

                    Text("Active for \(formatDuration(session.sessionDuration))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if session.isLocked, let reason = session.lockReason {
                HStack {
                    Image(systemName: "lock.fill")
                        .foregroundColor(.red)

                    Text("Locked: \(reason)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // Progress bar for timeout
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))

                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: geometry.size.width * (session.remainingTime / session.timeout))
                }
            }
            .frame(height: 4)
            .cornerRadius(2)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
#endif
