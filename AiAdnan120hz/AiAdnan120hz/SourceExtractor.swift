import Foundation
import PDFKit

// MARK: - Ekstraksi teks dari txt/md/pdf untuk fitur "Import Source".

enum SourceExtractor {
    static let maxChars = 60_000

    enum ExtractError: LocalizedError {
        case unreadable
        case empty
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .unreadable: return "File tidak bisa dibaca."
            case .empty: return "File kosong / tidak ada teks yang bisa diekstrak."
            case .tooLarge: return "File terlalu besar (batas 60 ribu karakter)."
            }
        }
    }

    static func extractText(from url: URL) throws -> String {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let text: String
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url), let s = doc.string, !s.isEmpty else {
                throw ExtractError.empty
            }
            text = s
        } else {
            guard let s = try? String(contentsOf: url, encoding: .utf8), !s.isEmpty else {
                throw ExtractError.unreadable
            }
            text = s
        }
        guard text.count <= maxChars * 4 else { throw ExtractError.tooLarge }
        return String(text.prefix(maxChars))
    }
}
