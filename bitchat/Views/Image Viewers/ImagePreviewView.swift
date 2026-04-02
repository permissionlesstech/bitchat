//
// ImagePreviewView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                if let image = platformImage {
                    #if os(iOS)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                    #else
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                    #endif
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Spacer()
                HStack {
                    Button(action: { dismiss() }) {
                        Text("close", comment: "Button to dismiss fullscreen media viewer")
                            .font(.bitchatSystem(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.5), lineWidth: 1))
                    }
                    Spacer()
                    Button(action: saveCopy) {
                        Text("save", comment: "Button to save media to device")
                            .font(.bitchatSystem(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.6)))
                    }
                }
                .padding([.horizontal, .bottom], 24)
            }
        }
        .onAppear(perform: loadImage)
        #if os(iOS)
        .sheet(isPresented: $showExporter) {
            FileExportWrapper(url: url)
        }
        #endif
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            #if os(iOS)
            guard let image = UIImage(contentsOfFile: url.path) else { return }
            #else
            guard let image = NSImage(contentsOf: url) else { return }
            #endif
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
            panel.prompt = "save"
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
            let controller = UIDocumentPickerViewController(forExporting: [url])
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
