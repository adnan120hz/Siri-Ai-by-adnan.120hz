import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Picker file dokumen untuk fitur baca file (premium).
/// Membungkus UIDocumentPickerViewController sebagai SwiftUI view.
///
/// Tipe yang dibuka: PDF, JPEG, PNG, ZIP, dan `.data` (untuk ipa/apk/raw
/// yang tidak punya UTType khusus). Ekstensi difilter SETELAH pick via
/// `supportedExtensions`; file yang tidak didukung dilaporkan lewat
/// `onUnsupportedType`, bukan dikarang/dibiarkan diam.
struct DocumentPickerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIDocumentPickerViewController

    /// Ekstensi yang didukung FileImportService (lowercase, tanpa titik).
    static let supportedExtensions: Set<String> = [
        "pdf",
        "jpg", "jpeg", "png",
        "zip", "ipa", "apk",
        "raw", "cr2", "nef", "dng", "arw"
    ]

    /// Dipanggil dengan URL file yang dipilih (dicopy ke sandbox karena asCopy=true).
    var onPick: (URL) -> Void
    /// Dipanggil saat user membatalkan picker.
    var onCancel: () -> Void
    /// Dipanggil saat ekstensi file tidak didukung. Default: abaikan.
    var onUnsupportedType: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .data menampung ipa/apk/raw/cr2/nef/dng/arw yang tak punya UTType khusus.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf, .jpeg, .png, .zip, .data],
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        // Tidak ada state yang perlu di-update.
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            let ext = url.pathExtension.lowercased()
            guard DocumentPickerView.supportedExtensions.contains(ext) else {
                parent.onUnsupportedType(ext.isEmpty ? "(tanpa ekstensi)" : ".\(ext)")
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
