//
// LoggingService.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import Foundation
import os

class LoggingService {
    static let shared = LoggingService()
    
    private let logger = Logger(subsystem: "com.bitchat", category: "general")
    private let fileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "bitchat.logging", qos: .background)
    
    private init() {
        // Set up date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        #if os(macOS)
        // Only create log files on macOS
        // Get documents directory
        let documentsPath = FileManager.default.urls(for: .documentDirectory, 
                                                    in: .userDomainMask).first!
        
        // Create logs directory
        let logsDirectory = documentsPath.appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: logsDirectory, 
                                               withIntermediateDirectories: true)
        
        // Create log file with today's date
        let dateString = DateFormatter.localizedString(from: Date(), 
                                                      dateStyle: .short, 
                                                      timeStyle: .none)
                                                      .replacingOccurrences(of: "/", with: "-")
        fileURL = logsDirectory.appendingPathComponent("bitchat-\(dateString).log")
        
        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        
        log("=== BitChat Started ===")
        log("Log file: \(fileURL.path)")
        #else
        // On iOS, just create a dummy URL since we won't write to disk
        fileURL = URL(fileURLWithPath: "/dev/null")
        #endif
    }
    
    func log(_ message: String, category: String = "general") {
        let timestamp = dateFormatter.string(from: Date())
        let logLine = "[\(timestamp)] [\(category)] \(message)\n"
        
        // Log to console for debugging
        print(logLine.trimmingCharacters(in: .newlines))
        
        // Log to system logger
        logger.log("\(message, privacy: .public)")
        
        // Write to file asynchronously
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if let data = logLine.data(using: .utf8) {
                do {
                    let fileHandle = try FileHandle(forWritingTo: self.fileURL)
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } catch {
                    print("Failed to write to log file: \(error)")
                }
            }
        }
    }
    
    func getLogFileURL() -> URL {
        return fileURL
    }
    
    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.fileURL, atomically: true, encoding: .utf8)
            self.log("=== Logs Cleared ===")
        }
    }
}

// Global logging function for convenience
func bitchatLog(_ message: String, category: String = "general") {
    LoggingService.shared.log(message, category: category)
}