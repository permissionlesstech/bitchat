//
// LogExportBuffer.swift
// BitLogger
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if DEBUG
import Foundation

/// In-memory ring buffer of the most recent sanitized log lines, so a tester
/// can export logs untethered when live streaming isn't available.
///
/// DEBUG-only: never compiled into release builds, matching the rest of the
/// logging stack. Bounded by both a line count and a byte budget (oldest
/// evicted first). Appends run on a private serial queue so a hot logging path
/// never blocks on buffer maintenance and the main thread is never touched.
///
/// It stores exactly the SecureLogger-sanitized text (fingerprints truncated,
/// base64 redacted, peer IDs shortened), so the export carries no secrets.
public final class LogExportBuffer {
    public static let shared = LogExportBuffer()

    private let queue = DispatchQueue(label: "chat.bitchat.securelogger.export", qos: .utility)
    private var lines: [String] = []
    private var byteCount = 0

    private let maxLines: Int
    private let maxBytes: Int

    init(maxLines: Int = 2000, maxBytes: Int = 512 * 1024) {
        self.maxLines = maxLines
        self.maxBytes = maxBytes
    }

    /// Append one already-formatted, already-sanitized log line. Non-blocking
    /// (async on the private queue).
    func append(_ line: String) {
        queue.async {
            self.lines.append(line)
            self.byteCount += line.utf8.count + 1 // + newline
            while self.lines.count > self.maxLines || self.byteCount > self.maxBytes {
                guard !self.lines.isEmpty else { break }
                let removed = self.lines.removeFirst()
                self.byteCount -= (removed.utf8.count + 1)
            }
        }
    }

    /// A newline-joined snapshot of the buffered lines, oldest first. Safe to
    /// call from the main thread (brief synchronous read).
    public func snapshot() -> String {
        queue.sync { lines.joined(separator: "\n") }
    }

    public func clear() {
        queue.async {
            self.lines.removeAll(keepingCapacity: true)
            self.byteCount = 0
        }
    }
}
#endif
