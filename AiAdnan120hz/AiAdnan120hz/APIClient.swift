import Foundation

// MARK: - Gemini client (Google AI Studio / Generative Language API).
// Key TANAM saat CI (enum Secrets, di-generate dari GitHub Secrets) —
// TIDAK PERNAH di-hardcode, tidak pernah di-log, tidak pernah via query string.
// Key hanya dikirim lewat header `x-goog-api-key` (format key baru "AQ."
// kena 401 palsu kalau lewat ?key=).

enum GeminiError: LocalizedError {
    /// 401/403: key salah / tidak diizinkan. STOP — jangan retry.
    case unauthorized
    /// 429: kuota habis. Sinyal khusus ke UI, jangan retry otomatis.
    case quotaExceeded
    /// 404: model tidak ada. Pemanggil boleh coba model fallback.
    case modelNotFound
    /// Error jaringan transient. Transport sudah retry 1x; ini hasil akhirnya.
    case network(Error)
    /// Respons tak bisa dibaca / status lain.
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "API key ditolak (401/403). Cek key di GitHub Secrets lalu rebuild."
        case .quotaExceeded:
            return "Kuota Gemini habis (429). Coba lagi nanti."
        case .modelNotFound:
            return "Model tidak tersedia (404)."
        case .network(let e):
            return "Jaringan: \(e.localizedDescription)"
        case .invalidResponse(let s):
            let short = s.count > 600 ? String(s.prefix(600)) + "…" : s
            return "Respons tak valid.\n\(short)"
        }
    }
}

// MARK: - Client

enum GeminiClient {
    /// User-Agent browser-like: beberapa gateway/WAF menolak request tanpa UA.
    /// Dipakai juga oleh GitHubClient.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Model utama dan fallback. JANGAN pakai alias `gemini-flash-latest`.
    static let primaryModel = "gemini-2.5-flash"
    static let fallbackModel = "gemini-2.0-flash"

    private static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models"

    // MARK: - Payload

    private struct Part: Encodable {
        var text: String?
        var inlineData: InlineData?

        struct InlineData: Encodable {
            var mimeType: String
            var data: String // base64 murni, tanpa prefix data:
        }

        enum CodingKeys: String, CodingKey { case text, inlineData }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(inlineData, forKey: .inlineData)
        }
    }

    private struct Content: Encodable {
        var role: String // "user" | "model"
        var parts: [Part]
    }

    private struct SystemInstruction: Encodable {
        var parts: [Part]
    }

    private struct GenerationConfig: Encodable {
        var maxOutputTokens: Int = 2048
        var temperature: Double = 0.7
    }

    private struct GenerateRequest: Encodable {
        var contents: [Content]
        var systemInstruction: SystemInstruction?
        var generationConfig = GenerationConfig()

        enum CodingKeys: String, CodingKey {
            case contents, systemInstruction, generationConfig
        }
    }

    private struct GenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { var text: String? }
                var parts: [Part]?
            }
            var content: Content?
        }
        struct ApiError: Decodable {
            var code: Int?
            var status: String?
            var message: String?
        }
        var candidates: [Candidate]?
        var error: ApiError?
    }

    // MARK: - Public API

    /// Kirim prompt teks. Selalu pakai SATU key tanam (Secrets.geminiFreeKey).
    /// Mengembalikan teks jawaban polos.
    /// `history`: riwayat [(role, text)] — role "user"/"assistant"/"model".
    /// Model utama dicoba dulu; kalau 404 → coba model fallback sekali.
    static func sendText(_ prompt: String,
                         history: [(role: String, text: String)] = [],
                         systemInstruction: String? = nil) async throws -> String {
        let key = Secrets.geminiFreeKey
        guard !key.isEmpty else { throw GeminiError.unauthorized }
        let sys = systemInstruction.map { SystemInstruction(parts: [Part(text: $0, inlineData: nil)]) }
        var contents = history.map { Content(role: geminiRole($0.role), parts: [Part(text: $0.text, inlineData: nil)]) }
        contents.append(Content(role: "user", parts: [Part(text: prompt, inlineData: nil)]))
        do {
            return try await requestOnce(key: key, model: primaryModel, contents: contents, systemInstruction: sys)
        } catch GeminiError.modelNotFound {
            // 404 → fallback model sekali, lalu selesai (sukses atau error final).
            return try await requestOnce(key: key, model: fallbackModel, contents: contents, systemInstruction: sys)
        }
    }

    /// Kirim prompt + gambar (JPEG/PNG bytes). `images`: (data, mimeType),
    /// mis. (jpegData, "image/jpeg"). Base64 di-encode di sini — panggil
    /// dengan bytes murni, tanpa prefix `data:`.
    static func sendWithImages(_ prompt: String,
                               images: [(data: Data, mimeType: String)],
                               history: [(role: String, text: String)] = [],
                               systemInstruction: String? = nil) async throws -> String {
        let key = Secrets.geminiFreeKey
        guard !key.isEmpty else { throw GeminiError.unauthorized }
        let sys = systemInstruction.map { SystemInstruction(parts: [Part(text: $0, inlineData: nil)]) }
        var contents = history.map { Content(role: geminiRole($0.role), parts: [Part(text: $0.text, inlineData: nil)]) }
        var parts: [Part] = [Part(text: prompt.isEmpty ? "Jelaskan gambar ini." : prompt, inlineData: nil)]
        for img in images {
            parts.append(Part(text: nil, inlineData: Part.InlineData(
                mimeType: img.mimeType,
                data: img.data.base64EncodedString())))
        }
        contents.append(Content(role: "user", parts: parts))
        do {
            return try await requestOnce(key: key, model: primaryModel, contents: contents, systemInstruction: sys)
        } catch GeminiError.modelNotFound {
            return try await requestOnce(key: key, model: fallbackModel, contents: contents, systemInstruction: sys)
        }
    }

    /// Gemini hanya kenal role "user"/"model". Petakan "assistant" → "model".
    private static func geminiRole(_ role: String) -> String {
        role == "assistant" ? "model" : role
    }

    // MARK: - Internal

    /// Satu request HTTP. Retry 1x HANYA untuk network error transient.
    /// 401/403/429/404 TIDAK di-retry — langsung jadi GeminiError bertipe.
    private static func requestOnce(key: String, model: String,
                                    contents: [Content],
                                    systemInstruction: SystemInstruction?) async throws -> String {
        let url = URL(string: "\(endpoint)/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let body = GenerateRequest(contents: contents, systemInstruction: systemInstruction)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // Retry sekali untuk network error, lalu serahkan sebagai .network.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                throw GeminiError.network(error)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200:
            break
        case 401, 403:
            throw GeminiError.unauthorized
        case 404:
            throw GeminiError.modelNotFound
        case 429:
            throw GeminiError.quotaExceeded
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GeminiError.invalidResponse("HTTP \(status)\n\(body)")
        }

        do {
            let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
            if let apiErr = decoded.error {
                // Body 200 tapi envelope error (jarang) — petakan status string.
                switch apiErr.status {
                case "UNAUTHENTICATED", "PERMISSION_DENIED": throw GeminiError.unauthorized
                case "RESOURCE_EXHAUSTED": throw GeminiError.quotaExceeded
                case "NOT_FOUND": throw GeminiError.modelNotFound
                default: throw GeminiError.invalidResponse(apiErr.message ?? "error tak dikenal")
                }
            }
            let text = (decoded.candidates?.first?.content?.parts ?? [])
                .compactMap(\.text).joined()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GeminiError.invalidResponse("candidates kosong")
            }
            return text
        } catch let e as GeminiError {
            throw e
        } catch {
            throw GeminiError.invalidResponse("decode: \(error.localizedDescription)")
        }
    }
}
