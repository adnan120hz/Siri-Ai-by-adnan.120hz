import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Picker file dokumen untuk fitur baca file (premium).
/// Membungkus UIDocumentPickerViewController sebagai SwiftUI view.
///
/// HANYA PDF dan ZIP yang bisa dipilih (keputusan user 2026-10-17).
/// Ekstensi difilter SETELAH pick via `supportedExtensions` sebagai
/// pengaman lapis kedua; file lain dilaporkan lewat `onUnsupportedType`.
struct DocumentPickerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIDocumentPickerViewController

    /// Ekstensi yang didukung (lowercase, tanpa titik): pdf + zip saja.
    static let supportedExtensions: Set<String> = ["pdf", "zip"]

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
        // Hanya PDF dan ZIP — tipe lain tidak bisa dipilih sama sekali.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf, .zip],
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
                parent.onUnsupportedType(ext.isEmpty ? "(no extension)" : ".\(ext)")
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
