//
// MacImagePickerView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(macOS)

import SwiftUI

struct MacImagePickerView: View {
    let completion: (URL?) -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Strings {
        static let title: LocalizedStringKey = "mac.image_picker.title"
        static let select = String(localized: "mac.image_picker.select", comment: "Button that opens the macOS open-panel to pick an image")
        static let panelMessage = String(localized: "mac.image_picker.panel_message", comment: "Message shown in the macOS NSOpenPanel when picking an image")
        static let cancel = String(localized: "mac.image_picker.cancel", comment: "Cancel button for the macOS image picker sheet")
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(Strings.title)
                .font(.headline)

            Button(Strings.select) {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.image, .png, .jpeg, .heic]
                panel.message = Strings.panelMessage

                if panel.runModal() == .OK {
                    completion(panel.url)
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)

            Button(Strings.cancel) {
                completion(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
        .frame(minWidth: 300, minHeight: 150)
    }
}

@available(OSX 14, *)
#Preview {
    @Previewable @State var isPresented = true
    @Previewable @State var selectedImage: NSImage?

    VStack {
        if let selectedImage {
            Image(nsImage: selectedImage)
                .resizable()
                .scaledToFit()
        } else {
            Text(String(localized: "image_picker.none_selected", defaultValue: "no image selected", comment: "Placeholder shown in the image picker before a selection"))
        }
        Button("Show") { isPresented = true }
    }
    .sheet(isPresented: $isPresented) {
        MacImagePickerView { url in
            selectedImage = url.map(NSImage.init)
            isPresented = false
        }
    }
}

#endif
