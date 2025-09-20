import Foundation
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

// Cross-platform file utilities inspired by Android FileUtils
enum FileUtils {
    static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension), let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    static func fileSize(url: URL) -> UInt64? {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? NSNumber { return size.uint64Value }
        } catch { }
        return nil
    }

    static func formatFileSize(_ bytes: UInt64) -> String {
        let units = ["B","KB","MB","GB"]
        var size = Double(bytes)
        var idx = 0
        while size >= 1024.0 && idx < units.count - 1 { size /= 1024.0; idx += 1 }
        return String(format: "%.1f %@", size, units[idx])
    }

    static func saveIncomingFile(_ packet: BitchatFilePacket, subdir: String? = nil) -> URL? {
        let baseDir: URL
        #if os(iOS)
        baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #else
        baseDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
        let isImage = packet.mimeType.lowercased().hasPrefix("image/")
        let sub = subdir ?? (isImage ? "images/incoming" : "files/incoming")
        let dir = baseDir.appendingPathComponent(sub, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // De-duplicate filename
        let sanitized = packet.fileName.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let ext = (sanitized as NSString).pathExtension
        var base = (sanitized as NSString).deletingPathExtension
        if base.isEmpty { base = isImage ? "img" : "file" }
        var candidate = dir.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
        var idx = 1
        while FileManager.default.fileExists(atPath: candidate.path) && idx < 1000 {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(idx))" : "\(base) (\(idx)).\(ext)")
            idx += 1
        }
        do {
            try packet.content.write(to: candidate)
            return candidate
        } catch {
            // Fallback to temp location
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
            try? packet.content.write(to: tmp)
            return tmp
        }
    }

    #if os(iOS)
    static func generateThumbnail(for url: URL, maxDimension: CGFloat = 256) -> UIImage? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let size = image.size
        let scale = max(size.width, size.height) / maxDimension
        if scale <= 1 { return image }
        let newSize = CGSize(width: size.width / scale, height: size.height / scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
    #endif
}
