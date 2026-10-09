import SwiftUI
import PhotosUI
import UIKit

/// Wraps `UIImagePickerController` in a SwiftUI-presentable so the
/// input bar can offer a Camera option. Image-only (no video) for
/// v1. On image capture, the delegate hands back raw JPEG bytes via
/// `onCaptured` so the caller can feed `relay.uploadChatAttachment`
/// without needing to understand UIImage. Catalyst doesn't expose
/// a camera and should never present this — gate the entry point
/// with `#if !targetEnvironment(macCatalyst)`.
struct CameraPicker: UIViewControllerRepresentable {
    /// Fires on capture with (jpegData, filename). The filename is
    /// synthesized from the capture timestamp.
    let onCaptured: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ v: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.85) {
                let name = "camera-\(Int(Date().timeIntervalSince1970)).jpg"
                parent.onCaptured(data, name)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Wraps `PHPickerViewController` for the Photo Library picker.
/// Multi-select (up to `selectionLimit`), images only. The delegate
/// loads each result's `UIImage` and invokes `onPicked` once with
/// the batch so the caller can show a single upload-progress strip
/// rather than one per pick.
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let selectionLimit: Int
    /// Fires once per selection session with (jpegData, filename)
    /// pairs. Called on the main actor.
    let onPicked: @MainActor ([(data: Data, filename: String)]) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = selectionLimit
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ v: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Load every selected item in parallel; batch the
            // results and hand them to the caller in one call so the
            // upload progress strip gets a clean "N files" start.
            Task { @MainActor in
                var batch: [(Data, String)] = []
                for (idx, result) in results.enumerated() {
                    let provider = result.itemProvider
                    guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
                    if let image: UIImage = await _loadImage(from: provider),
                       let data = image.jpegData(compressionQuality: 0.9) {
                        let name = provider.suggestedName ?? "photo-\(idx + 1)"
                        batch.append((data, "\(name).jpg"))
                    }
                }
                parent.onPicked(batch)
                parent.dismiss()
            }
        }
    }
}

private func _loadImage(from provider: NSItemProvider) async -> UIImage? {
    await withCheckedContinuation { cont in
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            cont.resume(returning: object as? UIImage)
        }
    }
}
