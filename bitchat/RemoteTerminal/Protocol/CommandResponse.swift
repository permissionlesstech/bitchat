//
// CommandResponse.swift
// Remote Terminal Protocol
//
// Response structure for executed commands
//

import Foundation

/// Response from executing a remote command
struct CommandResponse: Codable, Equatable {
    /// Unique identifier matching the original command
    let commandID: UUID

    /// Whether command executed successfully (exit code 0)
    let success: Bool

    /// Standard output (stdout) from command
    let output: String?

    /// Standard error (stderr) from command
    let error: String?

    /// Exit code from process
    let exitCode: Int32

    /// Timestamp when command completed
    let timestamp: Date

    /// Working directory where command was executed
    let workingDirectory: String?

    /// Optional binary data (for future use: file transfers, screenshots, etc.)
    let data: Data?

    init(
        commandID: UUID = UUID(),
        success: Bool,
        output: String? = nil,
        error: String? = nil,
        exitCode: Int32 = 0,
        timestamp: Date = Date(),
        workingDirectory: String? = nil,
        data: Data? = nil
    ) {
        self.commandID = commandID
        self.success = success
        self.output = output
        self.error = error
        self.exitCode = exitCode
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.data = data
    }
}

// MARK: - Convenience Constructors

extension CommandResponse {
    /// Create success response with output
    static func success(
        commandID: UUID = UUID(),
        output: String,
        workingDirectory: String? = nil
    ) -> CommandResponse {
        return CommandResponse(
            commandID: commandID,
            success: true,
            output: output,
            error: nil,
            exitCode: 0,
            workingDirectory: workingDirectory
        )
    }

    /// Create failure response with error
    static func failure(
        commandID: UUID = UUID(),
        error: String,
        exitCode: Int32 = 1,
        workingDirectory: String? = nil
    ) -> CommandResponse {
        return CommandResponse(
            commandID: commandID,
            success: false,
            output: nil,
            error: error,
            exitCode: exitCode,
            workingDirectory: workingDirectory
        )
    }

    /// Create response from Process execution
    static func fromProcess(
        commandID: UUID = UUID(),
        exitCode: Int32,
        stdout: String?,
        stderr: String?,
        workingDirectory: String?
    ) -> CommandResponse {
        return CommandResponse(
            commandID: commandID,
            success: exitCode == 0,
            output: stdout,
            error: stderr,
            exitCode: exitCode,
            workingDirectory: workingDirectory
        )
    }
}

// MARK: - Display Helpers

extension CommandResponse {
    /// Combined output (stdout + stderr) for display
    var displayOutput: String {
        var result = ""

        if let output = output, !output.isEmpty {
            result += output
        }

        if let error = error, !error.isEmpty {
            if !result.isEmpty {
                result += "\n"
            }
            result += error
        }

        if result.isEmpty {
            return success ? "Command completed successfully" : "Command failed"
        }

        return result
    }

    /// Short summary for logging
    var summary: String {
        let status = success ? "✅" : "❌"
        let code = "exit:\(exitCode)"
        let outputPreview = output?.prefix(50) ?? ""
        return "\(status) \(code) \(outputPreview)"
    }
}

// MARK: - Example Usage
/*

 // Success response
 let response1 = CommandResponse.success(
     output: "file1.txt\nfile2.txt\nREADME.md"
 )

 // Failure response
 let response2 = CommandResponse.failure(
     error: "npm: command not found",
     exitCode: 127
 )

 // From Process
 let response3 = CommandResponse.fromProcess(
     exitCode: process.terminationStatus,
     stdout: stdoutString,
     stderr: stderrString,
     workingDirectory: "/Users/user/dev"
 )

 // Display
 print(response1.displayOutput)  // Shows combined stdout+stderr
 print(response1.summary)        // ✅ exit:0 file1.txt...

 */
