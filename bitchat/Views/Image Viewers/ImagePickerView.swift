//
// ImagePickerView.swift
// bitchat
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

#if os(iOS)

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum PickedImage {
    case camera(UIImage)
    case photoLibraryFile(url: URL, cleanup: (() -> Void)?)
}

/// Camera or Photo Library
struct ImagePickerView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let completion: (PickedImage?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if sourceType == .photoLibrary {
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.filter = .images
            configuration.selectionLimit = 1
            configuration.preferredAssetRepresentationMode = .current

            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = context.coordinator
            picker.modalPresentationStyle = .fullScreen
            picker.overrideUserInterfaceStyle = .dark
            return picker
        }

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

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate, PHPickerViewControllerDelegate {
        let completion: (PickedImage?) -> Void

        init(completion: @escaping (PickedImage?) -> Void) {
            self.completion = completion
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            completion(image.map(PickedImage.camera))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            completion(nil)
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider else {
                completion(nil)
                return
            }

            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                UTType(identifier)?.conforms(to: .image) == true
            } ?? UTType.image.identifier

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [completion] sourceURL, error in
                guard error == nil, let sourceURL else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }

                do {
                    let stagedURL = try ImageUtils.stagePhotoLibraryImageFile(at: sourceURL, suggestedName: provider.suggestedName)
                    let cleanup: () -> Void = {
                        ImageUtils.removePhotoLibraryStagedImage(at: stagedURL)
                    }
                    DispatchQueue.main.async {
                        completion(.photoLibraryFile(url: stagedURL, cleanup: cleanup))
                    }
                } catch {
                    DispatchQueue.main.async { completion(nil) }
                }
            }
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
        ImagePickerView(sourceType: .photoLibrary) { picked in
            if case .camera(let image) = picked {
                selectedImage = image
            }
            isPresented = false
        }
    }
}

#endif
