import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoPicker: UIViewControllerRepresentable {
    let selected: (NSItemProvider?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let selected: (NSItemProvider?) -> Void
        init(selected: @escaping (NSItemProvider?) -> Void) { self.selected = selected }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            selected(results.first?.itemProvider)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let captured: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(captured: captured) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier]
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let captured: (UIImage?) -> Void
        init(captured: @escaping (UIImage?) -> Void) { self.captured = captured }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { captured(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            captured(info[.originalImage] as? UIImage)
        }
    }
}

struct FileShareSheet: UIViewControllerRepresentable {
    let file: WatermarkedFile

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum PhotoLibrary {
    static func read(_ provider: NSItemProvider) async throws -> Data {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true })
        else { throw PhotoError.unreadable }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data else { continuation.resume(throwing: PhotoError.unreadable); return }
                continuation.resume(returning: data)
            }
        }
    }

    static func save(_ file: WatermarkedFile) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoError.albumDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file.url, options: nil)
        }
    }
}
