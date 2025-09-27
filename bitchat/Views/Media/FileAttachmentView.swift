import SwiftUI

struct FileAttachmentView: View {
    private let url: URL
    private let isSending: Bool
    private let progress: Double?
    private let onCancel: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
    @State private var showExporter = false
    #endif

    init(url: URL, isSending: Bool, progress: Double?, onCancel: (() -> Void)?) {
        self.url = url
        self.isSending = isSending
        self.progress = progress
        self.onCancel = onCancel
    }

    private var fileName: String {
        url.lastPathComponent
    }

    private var normalizedProgress: Double? {
        guard let progress = progress else { return nil }
        return max(0, min(1, progress))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "doc.fill")
                .foregroundColor(Color.blue)
                .font(.bitchatSystem(size: 24))

            VStack(alignment: .leading, spacing: 4) {
                Text(fileName)
                    .font(.bitchatSystem(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                Text(url.path)
                    .font(.bitchatSystem(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let progress = normalizedProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color.blue)
                }
            }

            Spacer()

            Button(action: openFile) {
                Text("Open")
                    .font(.bitchatSystem(size: 13, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(Color.blue.opacity(0.15))
                    )
            }
            .buttonStyle(.plain)

            if let onCancel = onCancel, isSending {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.bitchatSystem(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.red.opacity(0.9)))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(colorScheme == .dark ? Color.black.opacity(0.6) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        #if os(iOS)
        .sheet(isPresented: $showExporter) {
            FileExportController(url: url)
        }
        #endif
    }

    private func openFile() {
        #if os(iOS)
        showExporter = true
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

#if os(iOS)
import UniformTypeIdentifiers
import UIKit

private struct FileExportController: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url])
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}
#else
import AppKit
#endif
