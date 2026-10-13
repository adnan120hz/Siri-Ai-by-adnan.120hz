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
        req.timeoutInterval = 20
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
        var tools: [ToolDef]?

        enum CodingKeys: String, CodingKey {
            case model, messages, max_tokens, temperature, stream, tools
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(model, forKey: .model)
            try c.encode(messages, forKey: .messages)
            try c.encode(max_tokens, forKey: .max_tokens)
            try c.encode(temperature, forKey: .temperature)
            try c.encodeIfPresent(stream, forKey: .stream)
            try c.encodeIfPresent(tools, forKey: .tools)
        }
    }

    // MARK: - Function calling (tools)

    struct PropSchema: Encodable {
        var type: String
        var description: String
    }

    struct ParamSchema: Encodable {
        var type: String = "object"
        var properties: [String: PropSchema]
        var required: [String]
    }

    struct FunctionDef: Encodable {
        var name: String
        var description: String
        var parameters: ParamSchema
    }

    struct ToolDef: Encodable {
        var type: String = "function"
        var function: FunctionDef
    }

    struct ToolCall: Decodable {
        var id: String
        struct Fn: Decodable { var name: String; var arguments: String }
        var function: Fn
    }

    /// Daftar tools GitHub untuk AI agent. Dikirim hanya kalau token GitHub terhubung.
    static let githubTools: [ToolDef] = [
        ToolDef(function: FunctionDef(
            name: "github_list_repos",
            description: "Daftar semua repository GitHub milik user yang terhubung. Pakai ini kalau user tanya soal repo GitHub-nya, mis. 'bisa konek github?', 'list repo ku', 'repo apa aja yang aku punya'.",
            parameters: ParamSchema(properties: [:], required: [])
        )),
        ToolDef(function: FunctionDef(
            name: "github_list_files",
            description: "Daftar file dalam sebuah repository. Parameter repo format 'owner/nama' (mis. 'adnan120hz/WorkSlop-Desktop-Version'). path_prefix opsional untuk filter folder.",
            parameters: ParamSchema(
                properties: [
                    "repo": PropSchema(type: "string", description: "Nama repo format 'owner/nama'"),
                    "path_prefix": PropSchema(type: "string", description: "Opsional: filter path, mis. 'src/'"),
                ],
                required: ["repo"]
            )
        )),
        ToolDef(function: FunctionDef(
            name: "github_read_file",
            description: "Baca isi sebuah file teks dari repository. Parameter repo format 'owner/nama', path adalah path file dalam repo.",
            parameters: ParamSchema(
                properties: [
                    "repo": PropSchema(type: "string", description: "Nama repo format 'owner/nama'"),
                    "path": PropSchema(type: "string", description: "Path file dalam repo, mis. 'README.md'"),
                ],
                required: ["repo", "path"]
            )
        )),
        ToolDef(function: FunctionDef(
            name: "github_write_file",
            description: "Buat file baru atau ubah isi file di repository, langsung auto-commit via GitHub Contents API (sama seperti edit di github.com). PENTING: JANGAN panggil tool ini tanpa persetujuan eksplisit user — tanya dulu di chat: sebutkan file yang akan diubah dan pesan commitnya, tunggu user bilang ya/setuju.",
            parameters: ParamSchema(
                properties: [
                    "repo": PropSchema(type: "string", description: "Nama repo format 'owner/nama'"),
                    "path": PropSchema(type: "string", description: "Path file dalam repo, mis. 'README.md' atau 'src/App.swift'"),
                    "content": PropSchema(type: "string", description: "Isi LENGKAP file (teks). Untuk edit, baca dulu file-nya lalu kirim versi lengkap yang sudah diubah."),
                    "message": PropSchema(type: "string", description: "Pesan commit, mis. 'Update README'"),
                ],
                required: ["repo", "path", "content"]
            )
        )),
        ToolDef(function: FunctionDef(
            name: "github_delete_file",
            description: "Hapus file dari repository, langsung auto-commit via GitHub Contents API. PENTING: JANGAN panggil tool ini tanpa persetujuan eksplisit user — tanya dulu di chat dan tunggu user bilang ya/setuju.",
            parameters: ParamSchema(
                properties: [
                    "repo": PropSchema(type: "string", description: "Nama repo format 'owner/nama'"),
                    "path": PropSchema(type: "string", description: "Path file dalam repo yang akan dihapus"),
                    "message": PropSchema(type: "string", description: "Pesan commit, mis. 'Hapus file lama'"),
                ],
                required: ["repo", "path"]
            )
        )),
    ]

    struct APIMessage: Encodable {
        var role: String
        var content: MessageContent
        /// Untuk pesan asisten dalam tool loop (OpenAI: tool_calls).
        var toolCalls: [ToolCallOut]? = nil
        /// Untuk pesan hasil tool (OpenAI: tool_call_id, role "tool").
        var toolCallId: String? = nil

        struct ToolCallOut: Encodable {
            var id: String
            var type: String = "function"
            var function: FunctionOut
            struct FunctionOut: Encodable {
                var name: String
                var arguments: String
            }
        }

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
            case toolCallId = "tool_call_id"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
            try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        }

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
            struct Message: Decodable {
                var content: String?
                var tool_calls: [ToolCall]?
            }
            var message: Message
            var finish_reason: String?
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

    // MARK: - Model free saja (prefix "free/")

    /// App ini HANYA memakai model free. Jangan pernah pakai ID tanpa prefix "free/".
    static func isFreeModel(_ id: String) -> Bool {
        id.lowercased().hasPrefix("free/")
    }

    /// Daftar fallback kalau /models kosong/gagal — 16 model free apinex.bond.
    static let freeModelFallback: [String] = [
        "free/glm-5.3-flash",
        "free/deepseek-v4.1-flash",
        "free/deepseek-v4-flash-0731",
        "free/deepseek-v4-pro-0813",
        "free/gpt-6-luna",
        "free/mimo-v2.6-pro",
        "free/mimo-v2.6-flash",
        "free/minimax-m3.1",
        "free/minimax-m3",
        "free/claude-sonnet-4.6",
        "free/claude-opus-4.6",
        "free/muse-spark-1.3",
        "free/gemini-3.1-pro",
        "free/kimi-k3",
        "free/kimi-k2.8",
        "free/hy4",
    ]

    /// Ambil daftar model dari server, saring HANYA yang free/.
    /// Kalau hasil saringan kosong → pakai fallback.
    static func fetchFreeModels(apiKey: String) async throws -> [String] {
        let all = try await fetchModels(apiKey: apiKey)
        let free = all.filter { isFreeModel($0) }
        return free.isEmpty ? freeModelFallback : free
    }

    private static func makeRequest(apiKey: String, model: String,
                                   messages: [APIMessage], stream: Bool,
                                   tools: [ToolDef]? = nil) -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        // Streaming: token pertama harus cepat, tapi jawaban panjang butuh waktu → 180.
        // Non-streaming: fail fast → 60. Tool loop: tiap putaran bisa panggil API → 90.
        req.timeoutInterval = stream ? 180 : (tools == nil ? 60 : 90)
        let body = Request(model: model, messages: messages,
                           max_tokens: 2048, temperature: 0.7,
                           stream: stream ? true : nil, tools: tools)
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

    /// Model menolak function calling (banyak model free kecil tidak support tools).
    struct ToolsNotSupported: Error {}

    /// Non-streaming dengan tools. Mengembalikan (teks jawaban, tool calls).
    /// Melempar `ToolsNotSupported` kalau server/gateway menolak parameter tools.
    static func sendChatWithTools(apiKey: String, model: String,
                                  messages: [APIMessage],
                                  tools: [ToolDef]) async throws -> (String?, [ToolCall]?) {
        let req = makeRequest(apiKey: apiKey, model: model, messages: messages,
                              stream: false, tools: tools)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw APIError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let low = body.lowercased()
            if low.contains("tool") || low.contains("function") {
                throw ToolsNotSupported()
            }
            throw APIError.http(status: status, body: body)
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let choice = decoded.choices.first else { throw APIError.emptyReply }
            return (choice.message.content, choice.message.tool_calls)
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
