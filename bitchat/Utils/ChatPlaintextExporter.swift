import BitFoundation
import Foundation

/// Formats on-device chat history as unsealed plaintext for export.
enum ChatPlaintextExporter {
    struct Context: Equatable {
        let scopeTitle: String
        let exportedAt: Date

        init(scopeTitle: String, exportedAt: Date = Date()) {
            self.scopeTitle = scopeTitle
            self.exportedAt = exportedAt
        }
    }

    static func exportText(messages: [BitchatMessage], context: Context) -> String {
        let header = [
            "bitchat export — \(context.scopeTitle)",
            "exported \(exportTimestamp(context.exportedAt))",
            "",
            warningLine,
            "",
        ].joined(separator: "\n")

        guard !messages.isEmpty else {
            return header + String(localized: "chat.export.empty", comment: "Line shown when an export contains no messages")
        }

        let body = messages.map { line(for: $0) }.joined(separator: "\n")
        return header + body + "\n"
    }

    private static var warningLine: String {
        String(
            localized: "chat.export.sealing_warning",
            comment: "Warning that an exported chat file is unsealed plaintext readable by anyone with a copy"
        )
    }

    private static func line(for message: BitchatMessage) -> String {
        let stamp = exportTimestamp(message.timestamp)
        let sender = message.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(stamp)] \(sender): \(content)"
    }

    private static func exportTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
