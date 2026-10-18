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
            case .unreadable: return "File could not be read."
            case .empty: return "File is empty / no text could be extracted."
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

    // MARK: - Fetch URL web → teks polos (untuk "Source Web")

    enum FetchError: LocalizedError {
        case badURL
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .badURL: return "Invalid URL."
            case .http(let s): return "Fetch failed (HTTP \(s))."
            case .empty: return "Page is empty / no text."
            }
        }
    }

    /// Ambil URL (mis. GitHub repo, docs, artikel) → teks bersih.
    static func fetchWebText(from urlString: String) async throws -> (title: String, text: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { throw FetchError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw FetchError.http(status) }
        guard var html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw FetchError.empty
        }
        // Judul halaman
        var title = url.host ?? s
        if let r = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            let t = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { title = t }
        }
        // Buang script/style, lalu semua tag.
        html = html.replacingOccurrences(of: "<script[^>]*>.*?</script>", with: " ", options: [.regularExpression, .caseInsensitive])
        html = html.replacingOccurrences(of: "<style[^>]*>.*?</style>", with: " ", options: [.regularExpression, .caseInsensitive])
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode entity umum
        for (e, c) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: e, with: c)
        }
        // Rapatkan whitespace
        text = text.replacingOccurrences(of: "[ \\t\\x0B\\f\\r]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FetchError.empty }
        return (title, String(text.prefix(maxChars)))
    }
}
