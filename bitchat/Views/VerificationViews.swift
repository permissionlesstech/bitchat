import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AVFoundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The user's verification QR on a white card, with their nickname under it.
/// The raw payload stays off-screen; the card's context menu copies it for
/// the macOS paste fallback.
struct MyQRView: View {
    let qrString: String
    let nickname: String
    @ThemedPalette private var palette

    private enum Strings {
        static let title: LocalizedStringKey = "verification.my_qr.title"
        static let copy: LocalizedStringKey = "common.copy"
        static let accessibilityLabel = String(localized: "verification.my_qr.accessibility_label", comment: "Accessibility label describing the verification QR code")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text(Strings.title)
                    .bitchatFont(size: 18, weight: .semibold)
                    .foregroundColor(palette.accent)
                    .multilineTextAlignment(.center)

                // White in every theme and color scheme: scanners need dark
                // modules on a light quiet zone. The hairline keeps the card
                // from dissolving into a white sheet in light mode.
                QRCodeImage(data: qrString, size: 240)
                    .accessibilityLabel(Strings.accessibilityLabel)
                    .padding(20)
                    .background(cardShape.fill(Color.white))
                    .overlay(cardShape.stroke(palette.divider, lineWidth: 1))
                    #if os(iOS)
                    .contentShape(.contextMenuPreview, cardShape)
                    #endif
                    .contextMenu {
                        Button(action: copyPayload) {
                            Label(Strings.copy, systemImage: "doc.on.doc")
                        }
                        .disabled(qrString.isEmpty)
                    }
                    .padding(.top, 24)

                Text(verbatim: nickname)
                    .bitchatFont(size: 24, weight: .semibold)
                    .foregroundColor(palette.primary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)

                Text(verbatim: "bitchat")
                    .bitchatFont(size: 15)
                    .foregroundColor(palette.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    private func copyPayload() {
        #if os(iOS)
        UIPasteboard.general.string = qrString
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(qrString, forType: .string)
        #endif
    }
}

// Render a QR code image for a given string using CoreImage
struct QRCodeImage: View {
    let data: String
    let size: CGFloat

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
                // Fixed dark ink: this always sits on MyQRView's white card,
                // where theme grays would wash out.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.black.opacity(0.2), lineWidth: 1)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(Strings.unavailable)
                            .bitchatFont(size: 12)
                            .foregroundColor(Color.black.opacity(0.6))
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

    @State private var camera: CameraAvailability = .available
    /// Bumped to rebuild the scanner, whose coordinator only checks camera
    /// access when it is created.
    @State private var scannerGeneration = 0

    #if os(iOS)
    private static let didBecomeActive = UIApplication.didBecomeActiveNotification
    #else
    private static let didBecomeActive = NSApplication.didBecomeActiveNotification
    #endif

    private enum CameraAvailability {
        case available
        /// The person turned camera access off; only Settings can undo that.
        case denied
        /// No camera, or access restricted by device management.
        case unavailable
    }

    private enum Strings {
        static let prompt: LocalizedStringKey = "verification.scan.prompt_friend"
        static let pastePrompt: LocalizedStringKey = "verification.scan.paste_prompt"
        static let validate: LocalizedStringKey = "verification.scan.validate"
        static let openSettings: LocalizedStringKey = "location_channels.action.open_settings"
        static let cameraUnavailable = String(
            localized: "verification.scan.camera_unavailable",
            defaultValue: "Camera unavailable — paste a QR below.",
            comment: "Shown over the scanner preview when no camera is available or permission was denied"
        )
        // iOS-only: macOS keeps the paste hint above, and CI's Periphery
        // scan (macOS scheme) would report these as dead code.
        #if os(iOS)
        static let cameraPermission = String(
            localized: "verification.scan.camera_permission",
            defaultValue: "allow camera access to scan a friend's QR",
            comment: "Shown in place of the scanner preview when camera access was denied"
        )
        static let noCamera = String(
            localized: "verification.scan.no_camera",
            defaultValue: "no camera available",
            comment: "Shown in place of the scanner preview when the device has no usable camera"
        )
        #endif
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

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    private var unavailableMessage: String {
        #if os(macOS)
        return Strings.cameraUnavailable
        #else
        return camera == .denied ? Strings.cameraPermission : Strings.noCamera
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                (camera == .available ? Color.black : palette.secondary.opacity(0.1))
                CameraScannerView(isActive: isActive, onUnavailable: handleCameraUnavailable) { code in
                    handleScannedCode(code, announceResult: false)
                }
                .id(scannerGeneration)
                // Hidden rather than removed: the coordinator lives on this view.
                .opacity(camera == .available ? 1 : 0)
                if camera == .available {
                    scanOverlay
                } else {
                    cameraUnavailableView
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            .clipShape(previewShape)

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
        .onReceive(NotificationCenter.default.publisher(for: Self.didBecomeActive)) { _ in
            recheckCameraAccess()
        }
    }

    /// Reticle plus caption pill over the live preview.
    private var scanOverlay: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.accent.opacity(0.8), lineWidth: 2)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 260)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)

            Text(Strings.prompt)
                .bitchatFont(size: 14)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                // Dark material in both schemes: it sits on camera video.
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
    }

    private var cameraUnavailableView: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .bitchatFont(size: 40, weight: .light)
                .foregroundColor(palette.accent)
                .accessibilityHidden(true)
            Text(unavailableMessage)
                .bitchatFont(size: 15)
                .foregroundColor(palette.primary)
                .multilineTextAlignment(.center)
            // iOS can't re-prompt once access is denied; send them to the
            // switch that can.
            if camera == .denied {
                Button(Strings.openSettings, action: SystemSettings.camera.open)
                    .bitchatFont(size: 15, weight: .medium)
                    .buttonStyle(.bordered)
                    .tint(palette.accent)
            }
        }
        .padding(24)
    }

    private func handleCameraUnavailable() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied:
            camera = .denied
        default:
            camera = .unavailable
        }
    }

    /// Back from Settings with access granted: the denied scanner already
    /// gave up, so swap in a fresh one that sees the new status.
    private func recheckCameraAccess() {
        guard camera == .denied,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        camera = .available
        scannerGeneration += 1
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
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> CameraScannerCoordinator { CameraScannerCoordinator() }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
        didConfigureSession = true
        return true
    }

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

// Combined sheet: my QR and the scanner as two segments, my QR first
struct VerificationSheetView: View {
    @EnvironmentObject private var verificationModel: VerificationModel
    @Binding var isPresented: Bool
    @State private var tab: Tab = .myQR
    @ThemedPalette private var palette

    private enum Tab: Hashable {
        case myQR
        case scan
    }

    private enum Strings {
        static let title: LocalizedStringKey = "verification.sheet.title"
        static let removeVerification: LocalizedStringKey = "fingerprint.action.remove_verification"
        static let tabPickerLabel = String(
            localized: "verification.tab.picker_label",
            defaultValue: "verification mode",
            comment: "Accessibility label for the my QR / scan segmented control in the verification sheet"
        )
        static let tabMyQR = String(
            localized: "verification.tab.my_qr",
            defaultValue: "my QR",
            comment: "Segment in the verification sheet that shows the user's own QR code"
        )
        static let tabScan = String(
            localized: "verification.tab.scan",
            defaultValue: "scan",
            comment: "Segment in the verification sheet that opens the QR scanner"
        )
    }

    private var accentColor: Color { palette.accent }

    var body: some View {
        VStack(spacing: 0) {
            // Top header (always at top)
            HStack {
                Text(Strings.title)
                    .bitchatFont(size: 14, weight: .bold)
                    .foregroundColor(accentColor)
                Spacer()
                SheetCloseButton {
                    isPresented = false
                }
                .foregroundColor(accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Picker(Strings.tabPickerLabel, selection: $tab) {
                Text(Strings.tabMyQR).tag(Tab.myQR)
                Text(Strings.tabScan).tag(Tab.scan)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Group {
                switch tab {
                case .myQR:
                    MyQRView(
                        qrString: verificationModel.myQRString(),
                        nickname: verificationModel.currentNickname
                    )
                case .scan:
                    // A successful scan lands back on my QR, so both sides
                    // can finish the exchange.
                    QRScanView(isActive: tab == .scan, onSuccess: { tab = .myQR })
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let peerID = verificationModel.selectedPeerID,
               verificationModel.isVerified(peerID: peerID) {
                Button(role: .destructive) {
                    verificationModel.unverifyFingerprint(for: peerID)
                } label: {
                    Label(Strings.removeVerification, systemImage: "minus.circle")
                        .bitchatFont(size: 15)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 620)
        #endif
        .themedSheetBackground()
        .onDisappear { tab = .myQR }
    }
}
