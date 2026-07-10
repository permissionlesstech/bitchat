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

    var body: some View {
        VStack(spacing: 16) {
            Text("Choose an image")
                .font(.headline)

            Button("Select Image") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.canChooseFiles = true
                panel.allowedContentTypes = [.image, .png, .jpeg, .heic]
                panel.message = "Choose an image to send"

                if panel.runModal() == .OK {
                    completion(panel.url)
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)

            Button("Cancel") {
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
            Text("No image selected")
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
