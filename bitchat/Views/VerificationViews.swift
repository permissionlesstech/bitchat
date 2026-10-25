import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Placeholder view to display the user's verification QR payload as text.
struct MyQRView: View {
    let qrString: String
    @Environment(\.colorScheme) var colorScheme
    @ThemedPalette private var palette
    // Palette-tinted so the box follows the theme (green under matrix)
    // instead of a fixed gray band over the glass gradient.
    private var boxColor: Color { palette.secondary.opacity(0.1) }

    private enum Strings {
        static let title: LocalizedStringKey = "verification.my_qr.title"
        static let accessibilityLabel = String(localized: "verification.my_qr.accessibility_label", comment: "Accessibility label describing the verification QR code")
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(Strings.title)
                .bitchatFont(size: 16, weight: .bold)

            VStack(spacing: 10) {
                QRCodeImage(data: qrString, size: 240)
                    .accessibilityLabel(Strings.accessibilityLabel)

                // Non-scrolling, fully visible URL (wraps across lines)
                Text(qrString)
                    .bitchatFont(size: 11)
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
    @ThemedPalette private var palette

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    private enum Strings {
        static let unavailable: LocalizedStringKey = "verification.my_qr.unavailable"
    }

    var body: some View {
        Group {
            if let image = generateImage() {
                ImageWrapper(image: image)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(Strings.unavailable)
                            .bitchatFont(size: 12)
                            .foregroundColor(palette.secondary)
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

/// Peer verification QR scanner. Uses the camera on iOS and macOS; macOS also
/// keeps a paste/validate fallback for machines without a usable camera.
struct QRScanView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @ThemedPalette private var palette
    var isActive: Bool = true
    var onSuccess: (() -> Void)? = nil  // Called when verification succeeds
    @State private var input = ""
    @State private var result: String = ""
    @State private var lastValid: String = ""

    @State private var cameraUnavailable = false

    private enum Strings {
        static let pastePrompt: LocalizedStringKey = "verification.scan.paste_prompt"
        static let validate: LocalizedStringKey = "verification.scan.validate"
        static let cameraUnavailable = String(
            localized: "verification.scan.camera_unavailable",
            defaultValue: "Camera unavailable — paste a QR below.",
            comment: "Shown over the scanner preview when no camera is available or permission was denied"
        )
        static func requested(_ nickname: String) -> String {
            String(
                format: String(localized: "verification.scan.status.requested", comment: "Status text when verification is requested for a nickname"),
                locale: .current,
                nickname
            )
        }
        static let notFound = String(localized: "verification.scan.status.no_peer", comment: "Status when no matching peer is found for a verification request")
        static let invalid = String(localized: "verification.scan.status.invalid", comment: "Status when a scanned QR payload is invalid")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                CameraScannerView(isActive: isActive, onUnavailable: { cameraUnavailable = true }) { code in
                    handleScannedCode(code, announceResult: false)
                }
                if cameraUnavailable {
                    Text(Strings.cameraUnavailable)
                        .bitchatFont(size: 13, weight: .medium)
                        .foregroundColor(palette.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }
            }
            // A centered square rather than a full-width 260pt strip, which
            // showed only a thin band of the camera on wide sheets (iPhone
            // Duo's inner display). The ideal width keeps the square from
            // collapsing where a sheet sizes itself to its content (macOS).
            .aspectRatio(1, contentMode: .fit)
            .frame(idealWidth: 360, maxWidth: 360)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)

            #if os(macOS)
            Text(Strings.pastePrompt)
                .bitchatFont(size: 14, weight: .medium)
            TextEditor(text: $input)
                .frame(height: 100)
                .border(palette.secondary.opacity(0.4))
            Button(Strings.validate) {
                handleScannedCode(input, announceResult: true)
            }
            .buttonStyle(.bordered)
            if !result.isEmpty {
                Text(result)
                    .bitchatFont(size: 12)
                    .foregroundColor(palette.secondary)
            }
            #endif
            Spacer()
        }
        .padding()
    }

    private func handleScannedCode(_ code: String, announceResult: Bool) {
        guard code != lastValid else {
            if announceResult {
                result = Strings.requested("")
            }
            return
        }

        switch verificationModel.verifyScannedPayload(code) {
        case .requested(let nickname):
            lastValid = code
            if announceResult {
                result = Strings.requested(nickname)
            }
            onSuccess?()
        case .notFound:
            if announceResult {
                result = Strings.notFound
            }
        case .invalid:
            if announceResult {
                result = Strings.invalid
            }
        }
    }
}

#if os(iOS)
struct CameraScannerView: UIViewRepresentable {
    typealias UIViewType = PreviewView
    var isActive: Bool
    var onUnavailable: (() -> Void)? = nil
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
        view.onEnterWindow = { [weak coordinator = context.coordinator] in
            coordinator?.refreshPreviewRotation()
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: CameraScannerCoordinator) {
        uiView.onEnterWindow = nil
        coordinator.stopPreviewRotationUpdates()
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onEnterWindow: (() -> Void)?
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { onEnterWindow?() }
        }
    }
}
#elseif os(macOS)
struct CameraScannerView: NSViewRepresentable {
    typealias NSViewType = PreviewView
    var isActive: Bool
    var onUnavailable: (() -> Void)? = nil
    var onCode: (String) -> Void

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: NSView {
        let videoPreviewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            videoPreviewLayer.videoGravity = .resizeAspectFill
            layer = CALayer()
            layer?.addSublayer(videoPreviewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            videoPreviewLayer.frame = bounds
        }
    }
}
#endif

final class CameraScannerCoordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    private var onCode: ((String) -> Void)?
    private var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private var isRunning = false
    private var permissionGranted = false
    private var desiredActive = false
    private var didConfigureSession = false
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    #if os(iOS)
    /// An `AVCaptureDevice.RotationCoordinator` (iOS 17+), stored untyped
    /// because a stored property can't carry an availability floor.
    private var rotationCoordinator: AnyObject?
    private var rotationObservation: NSKeyValueObservation?
    #endif

    func setup(
        previewLayer: AVCaptureVideoPreviewLayer,
        onCode: @escaping (String) -> Void,
        onUnavailable: (() -> Void)? = nil
    ) {
        self.onCode = onCode
        self.onUnavailable = onUnavailable
        self.previewLayer = previewLayer
        previewLayer.session = session

        // Check authorization before creating AVCaptureDeviceInput so tests and
        // cold launches do not trigger a TCC prompt just by constructing input.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            permissionGranted = true
            if !configureSessionIfNeeded() {
                reportUnavailable()
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    if granted {
                        if !self.configureSessionIfNeeded() {
                            self.reportUnavailable()
                            return
                        }
                        if self.desiredActive && !self.isRunning {
                            self.setActive(true)
                        }
                    } else {
                        self.reportUnavailable()
                    }
                }
            }
        default:
            permissionGranted = false
            reportUnavailable()
        }
    }

    @discardableResult
    private func configureSessionIfNeeded() -> Bool {
        guard !didConfigureSession else { return true }
        session.beginConfiguration()
        session.sessionPreset = .high
        // Ask for the back wide-angle camera by name: which camera
        // `default(for:)` picks is undocumented.
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)
        guard let device = camera,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        session.commitConfiguration()
        previewLayer?.session = session
        #if os(iOS)
        if #available(iOS 17.0, *) {
            startPreviewRotationUpdates(for: device)
        }
        #endif
        didConfigureSession = true
        return true
    }

    #if os(iOS)
    /// Keeps the camera preview upright. The portrait lock doesn't hold on
    /// iPhone Duo's inner display, so the interface can stand at any angle
    /// to the camera there; the coordinator works out the correction.
    @available(iOS 17.0, *)
    private func startPreviewRotationUpdates(for device: AVCaptureDevice) {
        stopPreviewRotationUpdates()
        guard let previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        // Updates arrive on the main queue.
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            self?.applyPreviewRotation(angle)
        }
    }

    /// Called once the preview is in a window. The coordinator reports 0°
    /// while its layer is off screen, so start a fresh one that can see the
    /// window; its initial update applies the real angle.
    func refreshPreviewRotation() {
        guard #available(iOS 17.0, *),
              let device = (rotationCoordinator as? AVCaptureDevice.RotationCoordinator)?.device else { return }
        startPreviewRotationUpdates(for: device)
    }

    func stopPreviewRotationUpdates() {
        rotationObservation?.invalidate()
        rotationObservation = nil
        rotationCoordinator = nil
    }

    @available(iOS 17.0, *)
    private func applyPreviewRotation(_ angle: CGFloat) {
        // The setter throws on an angle the connection doesn't support.
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
    #endif

    private func reportUnavailable() {
        DispatchQueue.main.async {
            self.onUnavailable?()
        }
    }

    func setActive(_ active: Bool) {
        desiredActive = active
        guard permissionGranted, didConfigureSession else { return }
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

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        for obj in metadataObjects {
            guard let m = obj as? AVMetadataMachineReadableCodeObject,
                  m.type == .qr,
                  let str = m.stringValue else { continue }
            onCode?(str)
        }
    }
}

// Combined sheet: shows my QR by default with a button to scan instead
struct VerificationSheetView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @Binding var isPresented: Bool
    @State private var showingScanner = false
    @ThemedPalette private var palette

    private var accentColor: Color { palette.accent }
    private var boxColor: Color { palette.secondary.opacity(0.1) }

    var body: some View {
        VStack(spacing: 0) {
            // Top header (always at top)
            HStack {
                Text("verification.sheet.title")
                    .bitchatFont(size: 14, weight: .bold)
                    .foregroundColor(accentColor)
                Spacer()
                SheetCloseButton {
                    showingScanner = false
                    isPresented = false
                }
                .foregroundColor(accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Content area. Scrolls between the pinned header and controls:
            // the QR code and its payload outgrow short sheets (iPhone Duo's
            // outer display, SE-class phones).
            ScrollView {
                Group {
                    if showingScanner {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("verification.scan.prompt_friend")
                                .bitchatFont(size: 16, weight: .bold)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .foregroundColor(accentColor)
                            QRScanView(isActive: showingScanner, onSuccess: {
                                showingScanner = false
                            })
                                .environmentObject(verificationModel)
                                .frame(minHeight: 280)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(boxColor)
                        .cornerRadius(8)
                    } else {
                        MyQRView(qrString: verificationModel.myQRString())
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            }

            // Centered controls moved up
            VStack(spacing: 10) {
                if showingScanner {
                    Button(action: { showingScanner = false }) {
                        Label("show my qr", systemImage: "qrcode")
                            .bitchatFont(size: 13)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: { showingScanner = true }) {
                        Label("scan someone else's qr", systemImage: "camera.viewfinder")
                            .bitchatFont(size: 13, weight: .medium)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }

                // Optional: Remove verification for selected peer (if verified)
                if let peerID = verificationModel.selectedPeerID,
                   verificationModel.isVerified(peerID: peerID) {
                    Button(action: { verificationModel.unverifyFingerprint(for: peerID) }) {
                        Label("remove verification", systemImage: "minus.circle")
                            .bitchatFont(size: 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .themedSheetBackground()
        .onDisappear { showingScanner = false }
    }
}
