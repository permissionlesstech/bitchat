//
// PairingManager.swift
// Remote Terminal - Mac Side
//
// Handles QR code generation and pairing requests for secure device connection
//

import Foundation
import AppKit
import CoreImage

/// Manages device pairing for remote terminal access
@MainActor
class PairingManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isPairingMode: Bool = false
    @Published var qrCodeImage: NSImage?
    @Published var pairingURL: String = ""

    // MARK: - Properties

    private let peerID: String
    private let deviceName: String
    fileprivate var pairingExpiresAt: Date?
    private let pairingTimeout: TimeInterval = 300 // 5 minutes

    // MARK: - Initialization

    init(peerID: String, deviceName: String = Host.current().localizedName ?? "Mac") {
        self.peerID = peerID
        self.deviceName = deviceName
    }

    // MARK: - Public API

    /// Start pairing mode and generate QR code
    func startPairing() {
        isPairingMode = true
        pairingExpiresAt = Date().addingTimeInterval(pairingTimeout)

        // Generate pairing URL
        // Format: bitchat://pair?peer=<peerID>&name=<deviceName>&expires=<timestamp>
        let timestamp = Int(pairingExpiresAt!.timeIntervalSince1970)
        pairingURL = "bitchat://pair?peer=\(peerID)&name=\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceName)&expires=\(timestamp)"

        // Generate QR code
        qrCodeImage = generateQRCode(from: pairingURL)

        print("📱 Pairing mode started")
        print("🔗 Pairing URL: \(pairingURL)")
        print("⏰ Expires at: \(pairingExpiresAt!)")

        // Auto-stop after timeout
        Task {
            try? await Task.sleep(nanoseconds: UInt64(pairingTimeout * 1_000_000_000))
            if isPairingMode {
                stopPairing()
            }
        }
    }

    /// Stop pairing mode
    func stopPairing() {
        isPairingMode = false
        qrCodeImage = nil
        pairingURL = ""
        pairingExpiresAt = nil

        print("📱 Pairing mode stopped")
    }

    /// Check if pairing URL is still valid
    func isPairingValid() -> Bool {
        guard let expiresAt = pairingExpiresAt else { return false }
        return Date() < expiresAt && isPairingMode
    }

    // MARK: - QR Code Generation

    private func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        // Create QR code filter
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel") // High error correction

        // Get output image
        guard let ciImage = filter.outputImage else { return nil }

        // Scale up for better quality
        let scale: CGFloat = 10
        let transformedImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Convert to NSImage
        let rep = NSCIImageRep(ciImage: transformedImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        return nsImage
    }

    /// Export QR code as PNG file
    func exportQRCode(to url: URL) throws {
        guard let image = qrCodeImage else {
            throw PairingError.noQRCode
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PairingError.imageConversionFailed
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw PairingError.imageConversionFailed
        }

        try pngData.write(to: url)
        print("💾 QR code saved to: \(url.path)")
    }
}

// Pairing URL parsing now in Protocol/PairingTypes.swift

// Supporting types now in Protocol/PairingTypes.swift

// MARK: - SwiftUI View for Mac

#if os(macOS)
import SwiftUI

struct PairingView: View {
    let peerID: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme

    private var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    private var pairingURL: String {
        let timestamp = Int(Date().addingTimeInterval(300).timeIntervalSince1970) // 5 minutes
        return "bitchat://pair?peer=\(peerID)&name=\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceName)&expires=\(timestamp)"
    }

    private var boxColor: Color {
        Color.gray.opacity(0.1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Pair iPhone with Mac")
                    .font(.bitchatSystem(size: 16, weight: .bold, design: .monospaced))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.top)

            VStack(spacing: 12) {
                VStack(spacing: 10) {
                    QRCodeImage(data: pairingURL, size: 240)

                    // Non-scrolling, fully visible URL (wraps across lines)
                    Text(pairingURL)
                        .font(.bitchatSystem(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .background(boxColor)
                        .cornerRadius(8)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(boxColor)
                .cornerRadius(8)

                Text("Scan this QR code with your iPhone in Remote Terminal")
                    .font(.bitchatSystem(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 450)
    }
}
#endif
