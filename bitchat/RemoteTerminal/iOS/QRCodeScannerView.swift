//
// QRCodeScannerView.swift
// Remote Terminal - iOS Side
//
// QR code scanner for pairing with Mac
//

#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

/// QR code scanner view for Mac pairing
struct QRCodeScannerView: View {
    @StateObject private var scannerManager = QRScannerManager()
    @State private var showingPairingConfirmation = false
    @State private var scannedPairingInfo: PairingInfo?
    @Environment(\.dismiss) private var dismiss

    let onPaired: (PairingInfo) -> Void

    var body: some View {
        ZStack {
            // Camera preview
            QRScannerViewRepresentable(scannerManager: scannerManager) { result in
                handleScanResult(result)
            }
            .edgesIgnoringSafeArea(.all)

            // Overlay UI
            VStack {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }

                    Spacer()

                    // Camera status indicator
                    HStack(spacing: 4) {
                        Circle()
                            .fill(scannerManager.permissionGranted ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(scannerManager.permissionGranted ? "Ready" : "No Permission")
                            .font(.caption)
                            .foregroundColor(.white)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                }
                .padding()

                Spacer()

                // Instructions
                VStack(spacing: 12) {
                    Text("Scan QR Code")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)

                    Text("Point camera at Mac screen")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
                .padding(.bottom, 40)
            }

            // Scanning frame
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.green, lineWidth: 3)
                .frame(width: 250, height: 250)
        }
        .alert("Trust this Mac?", isPresented: $showingPairingConfirmation) {
            Button("Cancel", role: .cancel) {
                scannedPairingInfo = nil
                scannerManager.startScanning()
            }

            Button("Trust") {
                if let info = scannedPairingInfo {
                    onPaired(info)
                    dismiss()
                }
            }
        } message: {
            if let info = scannedPairingInfo {
                Text("""
                Device: \(info.deviceName)
                Peer ID: \(info.peerID.prefix(16))...

                This will allow terminal access to your Mac.
                """)
            }
        }
        .onAppear {
            scannerManager.requestPermission()
        }
        .onDisappear {
            scannerManager.stopScanning()
        }
    }

    private func handleScanResult(_ result: Result<String, ScanError>) {
        switch result {
        case .success(let urlString):
            // Parse pairing URL
            if let pairingInfo = PairingInfo.parse(urlString) {
                // Check if expired
                guard !pairingInfo.isExpired else {
                    print("❌ Pairing QR code has expired")
                    scannerManager.startScanning()
                    return
                }

                // Show confirmation dialog
                scannedPairingInfo = pairingInfo
                showingPairingConfirmation = true
                scannerManager.stopScanning()

                print("✅ Valid pairing QR code scanned")
                print("   Device: \(pairingInfo.deviceName)")
                print("   Peer ID: \(pairingInfo.peerID)")
            } else {
                print("❌ Invalid pairing URL: \(urlString)")
                scannerManager.startScanning()
            }

        case .failure(let error):
            print("❌ Scan error: \(error)")
        }
    }
}

// MARK: - QR Scanner Manager

class QRScannerManager: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    @Published var permissionGranted = false
    @Published var isSessionRunning = false

    fileprivate var captureSession: AVCaptureSession?
    var onCodeScanned: ((Result<String, ScanError>) -> Void)?

    override init() {
        super.init()
        setupCaptureSession()
    }

    func requestPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            permissionGranted = true
            startScanning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.permissionGranted = granted
                    if granted {
                        self?.startScanning()
                    }
                }
            }
        default:
            permissionGranted = false
        }
    }

    private func setupCaptureSession() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            return
        }

        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            return
        }

        guard session.canAddInput(videoInput) else {
            return
        }

        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()

        guard session.canAddOutput(metadataOutput) else {
            return
        }

        session.addOutput(metadataOutput)

        // Set delegate and types AFTER adding output to session
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]
        metadataOutput.rectOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    func startScanning() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let session = self?.captureSession else {
                return
            }

            if !session.isRunning {
                session.startRunning()
                DispatchQueue.main.async {
                    self?.isSessionRunning = true
                }
            } else {
                DispatchQueue.main.async {
                    self?.isSessionRunning = true
                }
            }
        }
    }

    func stopScanning() {
        captureSession?.stopRunning()
        isSessionRunning = false
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !metadataObjects.isEmpty else {
            return
        }

        if let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           let stringValue = metadataObject.stringValue {
            // Vibrate to confirm QR detected
            DispatchQueue.main.async {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }

            onCodeScanned?(.success(stringValue))
        }
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        guard let session = captureSession else { return nil }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }
}

// MARK: - UIViewRepresentable for Camera Preview

struct QRScannerViewRepresentable: UIViewRepresentable {
    let scannerManager: QRScannerManager
    let onCodeScanned: (Result<String, ScanError>) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black

        if let previewLayer = scannerManager.previewLayer {
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
        }

        scannerManager.onCodeScanned = onCodeScanned

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = uiView.bounds
        }
    }
}

// MARK: - Supporting Types

enum ScanError: Error {
    case permissionDenied
    case deviceUnavailable
    case invalidCode
}

// MARK: - Preview

#if DEBUG
struct QRCodeScannerView_Previews: PreviewProvider {
    static var previews: some View {
        QRCodeScannerView { info in
            print("Paired with: \(info.deviceName)")
        }
    }
}
#endif

#endif // os(iOS)
