import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

// MARK: - Document picker (txt/md/pdf)

struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.text, .pdf], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - Camera picker (foto langsung → analisis AI)

struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (Data) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (Data) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            picker.dismiss(animated: true)
            if let img = info[.originalImage] as? UIImage,
               let data = img.jpegData(compressionQuality: 0.9) {
                onPick(data)
            }
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onCancel()
        }
    }
}

// MARK: - Photo library picker (PHPicker, tanpa perlu izin full library)

struct PhotoLibraryPicker: UIViewControllerRepresentable {
    var onPick: ([Data]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 4
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([Data]) -> Void
        init(onPick: @escaping ([Data]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else { return }
            let group = DispatchGroup()
            var datas: [Data] = []
            let lock = NSLock()
            for r in results {
                group.enter()
                r.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    if let data {
                        lock.lock(); datas.append(data); lock.unlock()
                    }
                }
            }
            group.notify(queue: .main) { self.onPick(datas) }
        }
    }
}

// MARK: - File picker khusus gambar (dari app Files)

struct ImageFilePicker: UIViewControllerRepresentable {
    var onPick: (Data) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (Data) -> Void
        init(onPick: @escaping (Data) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first,
                  let data = try? Data(contentsOf: url) else { return }
            onPick(data)
        }
    }
}
