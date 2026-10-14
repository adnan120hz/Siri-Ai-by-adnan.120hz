import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// Requires iOS 17+

// MARK: - Camera (photo capture).

struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let data = img.jpegData(compressionQuality: 0.85) {
                parent.onPick(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Photo library (PHPicker, no full-library permission needed).

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onPick: ([Data]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 4
        let p = PHPickerViewController(configuration: config)
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }
            var datas: [Data] = []
            let group = DispatchGroup()
            for r in results where r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    defer { group.leave() }
                    if let img = obj as? UIImage,
                       let data = img.jpegData(compressionQuality: 0.85) {
                        datas.append(data)
                    }
                }
            }
            group.notify(queue: .main) { self.parent.onPick(datas) }
        }
    }
}

// MARK: - Files (images + videos). Videos -> extracted frames so the AI can "see" them.

struct MediaFilePicker: UIViewControllerRepresentable {
    var onPick: ([Data]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.image, UTType.movie],
            asCopy: true
        )
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: MediaFilePicker
        init(_ parent: MediaFilePicker) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.dismiss()
            Task { @MainActor in
                var datas: [Data] = []
                for url in urls {
                    let isVideo = ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
                    if isVideo {
                        let frames = await MediaService.extractFrames(from: url)
                        datas.append(contentsOf: frames)
                    } else if let data = try? Data(contentsOf: url) {
                        datas.append(data)
                    }
                }
                parent.onPick(datas)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
