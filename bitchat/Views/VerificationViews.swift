import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Placeholder view to display the user's verification QR payload as text.
struct MyQRView: View {
    let qrString: String
    @Environment(\.colorScheme) var colorScheme
    private var boxColor: Color { Color.gray.opacity(0.1) }

    var body: some View {
        VStack(spacing: 12) {
            Text("scan to verify me")
                .font(.system(size: 16, weight: .bold, design: .monospaced))

            VStack(spacing: 10) {
                QRCodeImage(data: qrString, size: 240)
                    .accessibilityLabel("verification qr code")

                // Non-scrolling, fully visible URL (wraps across lines)
                Text(qrString)
                    .font(.system(size: 11, design: .monospaced))
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
        }
        .padding()
    }
}

// Render a QR code image for a given string using CoreImage
struct QRCodeImage: View {
    let data: String
    let size: CGFloat

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = generateImage() {
                ImageWrapper(image: image)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                    .frame(width: size, height: size)
                    .overlay(
                        Text("qr unavailable")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray)
                    )
            }
        }
    }

    private func generateImage() -> CGImage? {
        let inputData = Data(data.utf8)
        filter.message = inputData
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(1, Int(size / 32))
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return context.createCGImage(transformed, from: transformed.extent)
    }
}

// Platform-specific wrapper to display CGImage in SwiftUI
struct ImageWrapper: View {
    let image: CGImage
    var body: some View {
        #if os(iOS)
        let ui = UIImage(cgImage: image)
        return Image(uiImage: ui)
            .interpolation(.none)
            .resizable()
        #else
        let ns = NSImage(cgImage: image, size: .zero)
        return Image(nsImage: ns)
            .interpolation(.none)
            .resizable()
        #endif
    }
}

/// Placeholder scanner UI; real camera scanning will be added later.
struct QRScanView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    var isActive: Bool = true
    @State private var input = ""
    @State private var result: String = "" // not shown for iOS scanner
    @State private var lastValid: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            CameraScannerView(isActive: isActive) { code in
                if let qr = VerificationService.shared.verifyScannedQR(code) {
                    let ok = viewModel.beginQRVerification(with: qr)
                    if !ok { /* already pending; continue scanning */ }
                    lastValid = code
                } else {
                    // ignore invalid reads; continue scanning
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            #else
            Text("paste qr content to validate:")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
            TextEditor(text: $input)
                .frame(height: 100)
                .border(Color.gray.opacity(0.4))
            Button("validate") {
                if let qr = VerificationService.shared.verifyScannedQR(input) {
                    let ok = viewModel.beginQRVerification(with: qr)
                    result = ok ? "verification requested for \(qr.nickname)" : "could not find matching peer"
                } else {
                    result = "invalid or expired qr payload"
                }
            }
            .buttonStyle(.bordered)
            #endif
            // No status text under camera per design
            Spacer()
        }
        .padding()
    }
}

#if os(iOS)
import AVFoundation

struct CameraScannerView: UIViewRepresentable {
    typealias UIViewType = PreviewView
    var isActive: Bool
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(sessionOwner: view, onCode: onCode)
        context.coordinator.setActive(isActive)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private var onCode: ((String) -> Void)?
        private weak var owner: PreviewView?
        private let session = AVCaptureSession()
        private var isRunning = false
        private var permissionGranted = false
        private var desiredActive = false

        func setup(sessionOwner: PreviewView, onCode: @escaping (String) -> Void) {
            self.owner = sessionOwner
            self.onCode = onCode
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            sessionOwner.videoPreviewLayer.session = session
            // Request permission and start
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.permissionGranted = granted
                if granted && self.desiredActive && !self.isRunning {
                    self.setActive(true)
                }
            }
        }

        func setActive(_ active: Bool) {
            desiredActive = active
            guard permissionGranted else { return }
            if active && !isRunning {
                isRunning = true
                DispatchQueue.global(qos: .userInitiated).async {
                    if !self.session.isRunning { self.session.startRunning() }
                }
            } else if !active && isRunning {
                isRunning = false
                DispatchQueue.global(qos: .userInitiated).async {
                    if self.session.isRunning { self.session.stopRunning() }
                }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            for obj in metadataObjects {
                guard let m = obj as? AVMetadataMachineReadableCodeObject,
                      m.type == .qr,
                      let str = m.stringValue else { continue }
                onCode?(str)
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif

// Combined sheet: shows my QR by default with a button to scan instead
struct VerificationSheetView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    @State private var showingScanner = false
    @Environment(\.colorScheme) var colorScheme

    private var backgroundColor: Color { colorScheme == .dark ? Color.black : Color.white }
    private var accentColor: Color { colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0) }
    private var boxColor: Color { Color.gray.opacity(0.1) }

    private func myQRString() -> String {
        let npub = try? NostrIdentityBridge.getCurrentNostrIdentity()?.npub
        return VerificationService.shared.buildMyQRString(nickname: viewModel.nickname, npub: npub) ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top header (always at top)
            HStack {
                Text("VERIFY")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(accentColor)
                Spacer()
                Button(action: {
                    showingScanner = false
                    isPresented = false
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Content area
            Group {
                if showingScanner {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("scan a friend's qr")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .foregroundColor(accentColor)
                        #if os(iOS)
                        QRScanView(isActive: showingScanner)
                            .environmentObject(viewModel)
                            .frame(height: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        #else
                        QRScanView()
                            .environmentObject(viewModel)
                        #endif
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(boxColor)
                    .cornerRadius(8)
                } else {
                    let qr = myQRString()
                    MyQRView(qrString: qr)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Centered controls moved up
            VStack(spacing: 10) {
                if showingScanner {
                    Button(action: { showingScanner = false }) {
                        Label("show my qr", systemImage: "qrcode")
                            .font(.system(size: 13, design: .monospaced))
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: { showingScanner = true }) {
                        Label("scan someone else's qr", systemImage: "camera.viewfinder")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }

                // Optional: Remove verification for selected peer (if verified)
                if let pid = viewModel.selectedPrivateChatPeer,
                   let fp = viewModel.getFingerprint(for: pid),
                   viewModel.verifiedFingerprints.contains(fp) {
                    Button(action: { viewModel.unverifyFingerprint(for: pid) }) {
                        Label("remove verification", systemImage: "minus.circle")
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .background(backgroundColor)
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .onDisappear { showingScanner = false }
    }
}
