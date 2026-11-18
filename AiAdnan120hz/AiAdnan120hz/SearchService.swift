import Foundation

// MARK: - Tavily search grounding (https://api.tavily.com).
//
// Kenapa grounding, bukan "latihan ulang": model utama (gpt-oss-120b) data
// latihnya mentok 2024 dan tidak bisa dilatih ulang dari app. Jalan yang
// jujur: sebelum jawab pertanyaan soal info terbaru, cari dulu di web
// (Tavily), lalu suntikkan hasil pencarian sebagai konteks sistem ke Groq.
//
// Free tier "Researcher": 1.000 kredit/bulan, tanpa kartu.
//   - POST /search basic = 1 kredit/request (max_results 5).
//   - POST /extract = 1 kredit per 5 URL sukses.
// Key di Secrets.tavilyKey (di-generate dari env TAVILY_API_KEY).
// Key KOSONG/dummy = fitur mati dengan jujur: toggle "Cari di web" di
// ChatView tampil tapi nonaktif, auto-detect diam-diam tidak mencari.

enum SearchService {
    static let maxResults = 5
    /// Halaman yang diambil isinya (/extract) — 2 URL = 1 kredit.
    static let maxExtractURLs = 2

    /// True kalau ada key Tavily asli (bukan kosong, bukan dummy generate lokal).
    static var isConfigured: Bool {
        let k = Secrets.tavilyKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !k.isEmpty && k != "DUMMY_TAVILY_KEY"
    }

    struct WebResult {
        let title: String
        let url: String
        let snippet: String
        let publishedDate: String?
    }

    enum SearchError: LocalizedError {
        case notConfigured
        case unauthorized
        case quotaExceeded
        case network(Error)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Web search needs a free Tavily API key."
            case .unauthorized:
                return "Tavily API key rejected (401). Check TAVILY_API_KEY, then rebuild."
            case .quotaExceeded:
                return "Tavily quota exceeded (429). Try again later."
            case .network(let e):
                return "Web search network error: \(e.localizedDescription)"
            case .invalidResponse(let s):
                let short = s.count > 300 ? String(s.prefix(300)) + "…" : s
                return "Web search failed.\n\(short)"
            }
        }
    }

    // MARK: - Deteksi "butuh info terbaru"

    /// True kalau pertanyaan kemungkinan butuh info di luar data latih model
    /// (2024): ada tahun 2025/2026, kata "terbaru"/"hari ini"/"kemarin",
    /// atau topik yang berubah cepat (berita, harga, jadwal, cuaca, skor).
    /// Nama event spesifik tidak bisa ditebak dari kata kunci — itu tugas
    /// toggle "Cari di web" yang diaktifkan manual oleh user.
    static func needsFreshInfo(_ text: String) -> Bool {
        let lower = text.lowercased()
        let triggers = [
            "2025", "2026",
            "terbaru", "hari ini", "kemarin", "terkini", "saat ini", "sekarang",
            "berita", "update", "harga", "jadwal", "cuaca", "skor",
            "latest", "today", "yesterday", "news", "price", "weather", "current",
        ]
        return triggers.contains { lower.contains($0) }
    }

    // MARK: - Tavily /search

    private struct SearchRequest: Encodable {
        var api_key: String
        var query: String
        var search_depth: String = "basic"
        var max_results: Int = SearchService.maxResults
        var include_answer: Bool = false
    }

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            var title: String?
            var url: String?
            var content: String?
            var published_date: String?
        }
        var results: [Item]?
    }

    /// Cari di web. Throw kalau gagal — pemanggil jatuh kembali ke jawaban
    /// tanpa grounding (jangan memalsukan jawaban dari hasil kosong).
    static func search(_ query: String) async throws -> [WebResult] {
        guard isConfigured else { throw SearchError.notConfigured }
        let url = URL(string: "https://api.tavily.com/search")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(GroqClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        req.httpBody = try JSONEncoder().encode(
            SearchRequest(api_key: Secrets.tavilyKey, query: query))
        let (data, response) = try await dataWithNetworkError(req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 200:
            break
        case 401, 403:
            throw SearchError.unauthorized
        case 429:
            throw SearchError.quotaExceeded
        default:
            throw SearchError.invalidResponse("HTTP \(status)\n\(bodyText)")
        }
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return (decoded.results ?? []).compactMap { item in
            guard let title = item.title, !title.isEmpty,
                  let url = item.url, !url.isEmpty else { return nil }
            return WebResult(title: title, url: url,
                             snippet: item.content ?? "",
                             publishedDate: item.published_date)
        }
    }

    // MARK: - Tavily /extract (isi halaman, best-effort)

    private struct ExtractRequest: Encodable {
        var api_key: String
        var urls: [String]
        var query: String?
        var extract_depth: String = "basic"
    }

    private struct ExtractResponse: Decodable {
        struct Item: Decodable {
            var url: String?
            var raw_content: String?
        }
        var results: [Item]?
    }

    /// Ambil isi halaman untuk URL teratas (maks `maxExtractURLs`).
    /// Gagal sebagian/total = kembalikan yang berhasil saja (boleh kosong) —
    /// snippet dari /search tetap cukup untuk grounding.
    static func extractTopContents(_ results: [WebResult],
                                   query: String) async -> [String: String] {
        guard isConfigured else { return [:] }
        let urls = Array(results.prefix(maxExtractURLs)).map { $0.url }
        guard !urls.isEmpty else { return [:] }
        let url = URL(string: "https://api.tavily.com/extract")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(GroqClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        do {
            req.httpBody = try JSONEncoder().encode(
                ExtractRequest(api_key: Secrets.tavilyKey, urls: urls, query: query))
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { return [:] }
            let decoded = try JSONDecoder().decode(ExtractResponse.self, from: data)
            var out: [String: String] = [:]
            for item in decoded.results ?? [] {
                guard let u = item.url, let c = item.raw_content, !c.isEmpty else { continue }
                out[u] = String(c.prefix(6000))
            }
            return out
        } catch {
            return [:]
        }
    }

    // MARK: - Konteks grounding untuk Groq

    /// Susun blok konteks sistem dari hasil pencarian. Tanggal hari ini
    /// ditulis eksplisit supaya model tidak menebak tahun dari data latihnya.
    static func groundingContext(from results: [WebResult],
                                 extracts: [String: String]) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        var lines: [String] = [
            "WEB SEARCH RESULTS (today is \(today); your training data ends in 2024 — trust these results for anything recent):",
        ]
        for (i, r) in results.enumerated() {
            var head = "\(i + 1). \(r.title) — \(r.url)"
            if let d = r.publishedDate, !d.isEmpty { head += " (published \(d))" }
            lines.append(head)
            if !r.snippet.isEmpty { lines.append("   \(r.snippet.prefix(500))") }
            if let full = extracts[r.url], !full.isEmpty {
                lines.append("   Full text: \(full.prefix(2000))")
            }
        }
        lines.append("Use these results as the primary reference for recent facts. If the results do not cover the question, say so honestly instead of guessing.")
        return lines.joined(separator: "\n")
    }

    /// Daftar sumber ringkas untuk ditampilkan di bawah jawaban di ChatView.
    static func sourcesText(from results: [WebResult]) -> String {
        results.map { "• \($0.title) — \($0.url)" }.joined(separator: "\n")
    }

    // MARK: - Internal

    /// Satu request + 1x retry hanya untuk error jaringan transient.
    private static func dataWithNetworkError(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: req)
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                return try await URLSession.shared.data(for: req)
            } catch {
                throw SearchError.network(error)
            }
        }
    }
}
