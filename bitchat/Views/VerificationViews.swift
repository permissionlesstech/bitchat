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
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: size)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(palette.secondary.opacity(0.5), lineWidth: 1)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: size)
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
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))

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
        view.onLayout = { [weak coordinator = context.coordinator, weak view] in
            coordinator?.updatePreviewRotation(in: view?.window?.windowScene)
        }
        context.coordinator.setup(
            previewLayer: view.videoPreviewLayer,
            onCode: onCode,
            onUnavailable: onUnavailable
        )
        context.coordinator.setActive(isActive)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
        context.coordinator.updatePreviewRotation(in: uiView.window?.windowScene)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: CameraScannerCoordinator) {
        uiView.onLayout = nil
        coordinator.stopPreview()
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onLayout: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspect
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onLayout?()
        }
    }
}

/// The rotation coordinator observes the actual camera and preview layer, rather
/// than inferring camera direction from the shape of a resizable app window.
@available(iOS 17.0, *)
private final class CameraPreviewRotation {
    private let coordinator: AVCaptureDevice.RotationCoordinator
    private var observation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    init(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        // Apple delivers these updates on the main queue. The weak layer capture
        // keeps the observation from extending the preview's lifetime.
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak previewLayer] coordinator, _ in
            Self.apply(coordinator.videoRotationAngleForHorizonLevelPreview, to: previewLayer)
        }
    }

    func update() {
        Self.apply(coordinator.videoRotationAngleForHorizonLevelPreview, to: previewLayer)
    }

    private static func apply(_ angle: CGFloat, to previewLayer: AVCaptureVideoPreviewLayer?) {
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(angle),
              connection.videoRotationAngle != angle else { return }
        connection.videoRotationAngle = angle
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
            videoPreviewLayer.videoGravity = .resizeAspect
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
    // Type-erased storage keeps iOS 16 supported without initializing an iOS 17 API.
    private var previewRotation: AnyObject?
    private weak var previewWindowScene: UIWindowScene?
    // Keep a quick scanner dismissal from racing a pending startRunning call.
    private let sessionQueue = DispatchQueue(label: "chat.bitchat.verification-camera", qos: .userInitiated)
    #else
    private var sessionQueue: DispatchQueue { .global(qos: .userInitiated) }
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
        guard let device = AVCaptureDevice.default(for: .video),
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
        if #available(iOS 17.0, *), let previewLayer {
            previewRotation = CameraPreviewRotation(device: device, previewLayer: previewLayer)
        }
        #endif
        didConfigureSession = true
        #if os(iOS)
        updatePreviewRotation(in: previewWindowScene)
        #endif
        return true
    }

    #if os(iOS)
    func updatePreviewRotation(in windowScene: UIWindowScene?) {
        previewWindowScene = windowScene
        if #available(iOS 17.0, *) {
            (previewRotation as? CameraPreviewRotation)?.update()
        } else {
            // This is camera presentation, not a layout decision. Read only the
            // preview's scene; iOS 16 has no capture-device rotation coordinator.
            guard let orientation = windowScene?.interfaceOrientation,
                  let connection = previewLayer?.connection,
                  connection.isVideoOrientationSupported else { return }
            switch orientation {
            case .portrait: connection.videoOrientation = .portrait
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            default: break
            }
        }
    }

    func stopPreview() {
        previewRotation = nil
        setActive(false)
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
            sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        } else if !active && isRunning {
            isRunning = false
            sessionQueue.async {
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
        NavigationStack {
            ScrollView {
                verificationContent
            }
            .navigationTitle("verification.sheet.title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton {
                        showingScanner = false
                        isPresented = false
                    }
                }
            }
        }
        .themedSheetBackground()
        .onDisappear { showingScanner = false }
    }

    private var verificationContent: some View {
        VStack(spacing: 0) {
            // Content area
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

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
    }
}
