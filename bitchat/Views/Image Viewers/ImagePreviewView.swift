//
// ImagePreviewView.swift
// bitchat
//
// Fullscreen media viewer with pinch/double-tap zoom, pan, native share,
// and floating Liquid Glass controls.
// This is free and unencumbered software released into the public domain.
//

import SwiftUI
#if os(macOS)
import BitLogger
#endif

struct ImagePreviewView: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var showExporter = false
    @State private var platformImage: UIImage?
    #else
    @State private var platformImage: NSImage?
    #endif
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if let image = platformImage {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    #endif
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .scaleEffect(zoomScale)
            .offset(panOffset)
            .padding()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        let next = lastZoomScale * value
                        zoomScale = min(max(next, 1.0), 4.0)
                    }
                    .onEnded { _ in
                        lastZoomScale = zoomScale
                        if zoomScale <= 1.02 {
                            resetZoom()
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard zoomScale > 1.01 else { return }
                        panOffset = CGSize(
                            width: lastPanOffset.width + value.translation.width,
                            height: lastPanOffset.height + value.translation.height
                        )
                    }
                    .onEnded { _ in
                        guard zoomScale > 1.01 else { return }
                        lastPanOffset = panOffset
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    if zoomScale > 1.05 {
                        resetZoom()
                    } else {
                        zoomScale = 2.5
                        lastZoomScale = 2.5
                    }
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "close", defaultValue: "Close", comment: "Button to dismiss fullscreen media viewer"))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                HStack(spacing: 12) {
                    ShareLink(item: url) {
                        Label(
                            String(localized: "common.share", defaultValue: "Share", comment: "Button to share media"),
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.bitchatSystem(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: saveCopy) {
                        Label(
                            String(localized: "save", defaultValue: "Save", comment: "Button to save media to device"),
                            systemImage: "square.and.arrow.down"
                        )
                        .font(.bitchatSystem(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 28)
            }
        }
        .onAppear(perform: loadImage)
        #if os(iOS)
        .sheet(isPresented: $showExporter) {
            FileExportWrapper(url: url)
        }
        #endif
    }

    private func resetZoom() {
        zoomScale = 1.0
        lastZoomScale = 1.0
        panOffset = .zero
        lastPanOffset = .zero
    }

    private func loadImage() {
        let imageURL = url
        if let cached = ImageDownsampler.cachedImage(
            for: imageURL,
            maxPixelSize: ImageDownsampler.fullScreenMaxPixelSize
        ) {
            self.platformImage = cached
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = ImageDownsampler.loadDownsampledImage(
                from: imageURL,
                maxPixelSize: ImageDownsampler.fullScreenMaxPixelSize
            ) else { return }
            DispatchQueue.main.async {
                self.platformImage = image
            }
        }
    }

    private func saveCopy() {
        #if os(iOS)
        showExporter = true
        #else
        Task { @MainActor in
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = url.lastPathComponent
            panel.prompt = "Save"
            if panel.runModal() == .OK, let destination = panel.url {
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    SecureLogger.error("Failed to save image preview copy: \(error)", category: .session)
                }
            }
        }
        #endif
    }

    #if os(iOS)
    private struct FileExportWrapper: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            controller.shouldShowFileExtensions = true
            return controller
        }

        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    }
    #endif
}

#Preview {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("dummy.jpg")
    if !FileManager.default.fileExists(atPath: tempURL.path(percentEncoded: false)) {
        #if os(iOS)
        let image = UIImage(named: "dummy")
        let data = image?.jpegData(compressionQuality: 0.8)
        let _ = try? data?.write(to: tempURL)
        #elseif os(macOS)
        let image = NSImage(named: "dummy")
        var rect = NSRect(origin: .zero, size: image?.size ?? .zero)
        if let cgImage = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            let _ = try? jpegData?.write(to: tempURL)
        }
        #endif
    }
    ImagePreviewView(url: tempURL)
}
