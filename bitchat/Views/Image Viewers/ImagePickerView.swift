//
// ImagePickerView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import SwiftUI

/// Camera or Photo Library
struct ImagePickerView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let completion: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = false

        // Use standard full screen - iOS handles safe areas automatically
        picker.modalPresentationStyle = .fullScreen

        // Force dark mode to make safe area bars black instead of white
        picker.overrideUserInterfaceStyle = .dark

        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void

        init(completion: @escaping (UIImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            completion(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }
    }
}

@available(iOS 17, *)
#Preview {
    @Previewable @State var isPresented = true
    @Previewable @State var selectedImage: UIImage?
    VStack {
        if let selectedImage {
            Image(uiImage: selectedImage)
                .resizable()
                .scaledToFit()
        } else {
            Text("No image selected")
        }
        Button("Show") { isPresented = true }
    }
    .sheet(isPresented: $isPresented) {
        ImagePickerView(sourceType: .photoLibrary) { image in
            selectedImage = image
            isPresented = false
        }
    }
}

#endif
