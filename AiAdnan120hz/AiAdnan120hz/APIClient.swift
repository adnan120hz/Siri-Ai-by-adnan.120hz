import Foundation

// MARK: - APInex (OpenAI-compatible) — semua lewat URLSession, tanpa fake.

enum APIError: LocalizedError {
    case noKey
    case http(status: Int, body: String)
    case network(URLError)
    case decoding(String)
    case emptyReply

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "API key belum dipasang. Buka Pengaturan → API Key."
        case .http(let status, let body):
            let short = body.count > 600 ? String(body.prefix(600)) + "…" : body
            return "HTTP \(status)\n\(short)"
        case .network(let e):
            return "Jaringan: \(e.localizedDescription)"
        case .decoding(let s):
            return "Gagal baca respons: \(s)"
        case .emptyReply:
            return "Respons kosong dari server."
        }
    }
}

// MARK: - Model payload

struct APInexClient {
    static let baseURL = URL(string: "https://api.apinex.bond/v1")!

    /// User-Agent browser-like: beberapa gateway/WAF menolak request tanpa UA.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    // --- /models ---

    struct ModelItem: Decodable { var id: String }
    struct ModelList: Decodable { var data: [ModelItem]? }

    static func fetchModels(apiKey: String) async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw APIError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            return (list.data ?? []).map(\.id).sorted()
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // --- /chat/completions ---

    struct Request: Encodable {
        var model: String
        var messages: [APIMessage]
        var max_tokens: Int
        var temperature: Double
        var stream: Bool?
    }

    struct APIMessage: Encodable {
        var role: String
        var content: MessageContent

        /// Teks kasar untuk estimasi token (tidak dikirim ke server).
        var debugText: String {
            switch content {
            case .text(let t): return t
            case .parts(let ps):
                return ps.map {
                    switch $0 {
                    case .text(let t): return t
                    case .image: return "[gambar]"
                    }
                }.joined(separator: " ")
            }
        }
    }

    enum MessageContent: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let t): try c.encode(t)
            case .parts(let p): try c.encode(p)
            }
        }
    }

    enum ContentPart: Encodable {
        case text(String)
        case image(dataURL: String)

        enum CodingKeys: String, CodingKey { case type, text, image_url }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let t):
                try c.encode("text", forKey: .type)
                try c.encode(t, forKey: .text)
            case .image(let url):
                try c.encode("image_url", forKey: .type)
                try c.encode(["url": url], forKey: .image_url)
            }
        }
    }

    struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message
        }
        var choices: [Choice]
    }

    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { var content: String? }
            var delta: Delta
        }
        var choices: [Choice]
    }

    struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            var message: String?
            var type: String?
            var code: String?
        }
        var error: Detail?
    }

    // MARK: - Audio: STT (/audio/transcriptions) & TTS (/audio/speech)

    /// Model default OpenAI-compatible. Kalau APInex memakai ID lain,
    /// server akan mengembalikan error yang jelas di UI.
    static let sttModel = "whisper-1"
    static let ttsModel = "tts-1"

    struct TranscriptionResponse: Decodable { var text: String? }

    /// STT via API: upload file audio (multipart) → teks.
    static func transcribeAudio(apiKey: String, audioURL: URL, language: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        let audioData = try Data(contentsOf: audioURL)
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("model", sttModel)
        field("language", language)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw APIError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
            guard let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw APIError.emptyReply
            }
            TokenUsage.record(tokens: TokenUsage.estimateTokens(for: text) + 50)
            return text
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    struct SpeechRequest: Encodable {
        var model: String
        var input: String
        var voice: String
        var speed: Double
        var instructions: String?
    }

    /// TTS via API: teks → byte audio (mp3/wav, tergantung server).
    static func synthesizeSpeech(apiKey: String, text: String, voice: String,
                                 speed: Double, style: String?) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent("audio/speech"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        let body = SpeechRequest(model: ttsModel, input: text, voice: voice,
                                 speed: speed, instructions: style)
        req.httpBody = try? JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw APIError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200, !data.isEmpty else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        TokenUsage.record(tokens: TokenUsage.estimateTokens(for: text))
        return data
    }

    // MARK: - Tier akun (free / paid)
    enum AccountTier: String {
        case unknown, free, paid
    }

    /// Model dengan prefix "free/" = model gratis. Selain itu = paid.
    static func isFreeModel(_ id: String) -> Bool {
        id.lowercased().hasPrefix("free/")
    }

    /// Deteksi tier dengan probe murah: panggil model paid dengan max_tokens=1.
    /// - 200 → paid (boleh pakai semua model)
    /// - 402/403 → free tier (model paid diblokir)
    /// - 401 → key tidak valid (throw)
    /// - lainnya → unknown (jangan blokir, jangan berasumsi)
    static func detectTier(apiKey: String, paidModelId: String) async throws -> AccountTier {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let body = Request(model: paidModelId,
                           messages: [APIMessage(role: "user", content: .text("hi"))],
                           max_tokens: 1, temperature: 0, stream: nil)
        req.httpBody = try? JSONEncoder().encode(body)
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw APIError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200: return .paid
        case 402, 403: return .free
        case 401: throw APIError.http(status: status, body: "API key tidak valid.")
        default: return .unknown
        }
    }

    private static func makeRequest(apiKey: String, model: String,
                                   messages: [APIMessage], stream: Bool) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        let body = Request(model: model, messages: messages,
                           max_tokens: 2048, temperature: 0.7, stream: stream ? true : nil)
        req.httpBody = try? JSONEncoder().encode(body)
        return req
    }

    /// Non-streaming. Selalu mengembalikan body error asli saat HTTP != 200.
    static func sendChat(apiKey: String, model: String,
                         messages: [APIMessage]) async throws -> String {
        let req = makeRequest(apiKey: apiKey, model: model, messages: messages, stream: false)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw APIError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw APIError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
                throw APIError.emptyReply
            }
            return text
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    /// Streaming SSE sebagai AsyncThrowingStream.
    /// Melempar `StreamSetupFailed` kalau server menolak, supaya pemanggil
    /// bisa fallback ke non-streaming (yang memberi body error lengkap).
    struct StreamSetupFailed: Error { var status: Int }

    static func streamChat(apiKey: String, model: String,
                           messages: [APIMessage]) -> AsyncThrowingStream<String, Error> {
        let req = makeRequest(apiKey: apiKey, model: model, messages: messages, stream: true)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    guard status == 200 else {
                        continuation.finish(throwing: StreamSetupFailed(status: status))
                        return
                    }
                    var gotAnything = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                           let token = chunk.choices.first?.delta.content, !token.isEmpty {
                            gotAnything = true
                            continuation.yield(token)
                        }
                    }
                    if !gotAnything {
                        continuation.finish(throwing: APIError.emptyReply)
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
