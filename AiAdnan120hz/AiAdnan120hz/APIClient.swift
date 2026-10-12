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

    // --- /models ---

    struct ModelItem: Decodable { var id: String }
    struct ModelList: Decodable { var data: [ModelItem] }

    static func fetchModels(apiKey: String) async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            return list.data.map(\.id).sorted()
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // --- /chat/completions ---

    struct Request: Encodable {
        var model: String
        var messages: [APIMessage]
        var max_tokens: Int
        var stream: Bool?
    }

    struct APIMessage: Encodable {
        var role: String
        var content: MessageContent
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

    private static func makeRequest(apiKey: String, model: String,
                                   messages: [APIMessage], stream: Bool) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        let body = Request(model: model, messages: messages,
                           max_tokens: 2048, stream: stream ? true : nil)
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
