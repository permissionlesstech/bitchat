import CoreGraphics
import Foundation
import ImageIO

/// Deterministic, spec-compliant image fixtures for media-ingest tests.
enum TestImageFixtures {
    static func makeJPEG(width: Int = 1, height: Int = 1, comment: Data? = nil) -> Data {
        var encoded = encodeImage(width: width, height: height, uti: "public.jpeg")
        if let comment, !comment.isEmpty, encoded.count >= 2, encoded[0] == 0xFF, encoded[1] == 0xD8 {
            // Insert a standard JPEG COM (0xFF 0xFE) segment right after SOI.
            let maxBody = Int(UInt16.max) - 2
            let body = comment.prefix(maxBody)
            var segment = Data([0xFF, 0xFE])
            var length = UInt16(body.count + 2).bigEndian
            withUnsafeBytes(of: &length) { segment.append(contentsOf: $0) }
            segment.append(body)
            encoded.insert(contentsOf: segment, at: 2)
        }
        return encoded
    }

    static func makePNG(width: Int = 1, height: Int = 1) -> Data {
        encodeImage(width: width, height: height, uti: "public.png")
    }

    /// Builds a valid minimal PNG header claiming arbitrary dimensions (e.g.
    /// 32768x32768) in under 60 bytes — a classic decompression-bomb header
    /// that ImageIO metadata inspection reads without allocating pixel memory.
    static func makePNGBomb(width: UInt32, height: UInt32) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        var w = width.bigEndian
        var h = height.bigEndian
        withUnsafeBytes(of: &w) { ihdr.append(contentsOf: $0) }
        withUnsafeBytes(of: &h) { ihdr.append(contentsOf: $0) }
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, deflate, standard filter, non-interlaced

        appendPNGChunk(type: "IHDR", body: ihdr, to: &data)
        appendPNGChunk(type: "IEND", body: Data(), to: &data)
        return data
    }

    private static func encodeImage(width: Int, height: Int, uti: String) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return Data()
        }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else { return Data() }

        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, uti as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return output as Data
    }

    private static func appendPNGChunk(type: String, body: Data, to output: inout Data) {
        let typeBytes = Data(type.utf8)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(typeBytes)
        output.append(body)
        var crc = crc32(typeBytes + body).bigEndian
        withUnsafeBytes(of: &crc) { output.append(contentsOf: $0) }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
