import Foundation

// MARK: - Groq client (OpenAI-compatible: https://api.groq.com/openai/v1).
// Key EMBEDDED at CI (enum Secrets, generated from GitHub Secrets) —
// NEVER hardcoded, never logged, never via query string.
// Key is sent only via `Authorization: Bearer` header.
// NOTE: the secret env names GEMINI_API_KEY_FREE / GEMINI_API_KEY_PREMIUM are
// kept for continuity, but their values are GROQ keys (set by the user).

enum GroqError: LocalizedError {
    /// 401/403: wrong key / not allowed. STOP — do not retry.
    case unauthorized
    /// 429: quota exhausted. Special signal to UI, do not auto-retry.
    case quotaExceeded
    /// 404 (or 400 with "model" in body): model missing / key has no access.
    /// Caller may try the fallback model once.
    /// `usingPremiumKey` = true → error message points at the premium key.
    case modelNotFound(usingPremiumKey: Bool = false)
    /// Transient network error. Transport already retried 1x; this is final.
    case network(Error)
    /// Response unreadable / other status.
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "API key rejected (401/403). Check the key in GitHub Secrets, then rebuild."
        case .quotaExceeded:
            return "Groq quota exceeded (429). Try again later."
        case .modelNotFound(let usingPremiumKey):
            if usingPremiumKey {
                return "Premium key problem (404). Check GEMINI_API_KEY_PREMIUM in GitHub Secrets — it holds a Groq key, make sure it is a valid new key, then rebuild."
            }
            return "Model unavailable (404)."
        case .network(let e):
            return "Network: \(e.localizedDescription)"
        case .invalidResponse(let s):
            let short = s.count > 600 ? String(s.prefix(600)) + "…" : s
            return "Invalid response.\n\(short)"
        }
    }
}

// MARK: - Client

enum GroqClient {
    /// Browser-like User-Agent: some gateways/WAFs reject requests without UA.
    /// Also used by GitHubClient.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Primary and fallback chat models (free Developer plan).
    static let primaryModel = "openai/gpt-oss-120b"
    static let fallbackModel = "openai/gpt-oss-20b"
    /// Vision model for sendWithImages (OpenAI image_url format).
    /// NOTE: Groq free tier currently lists no vision model; this ID is kept
    /// so image input works again if Groq re-adds one. A 404 surfaces honestly.
    static let visionModel = "meta-llama/llama-4-scout-17b-16e-instruct"

    private static let endpoint = "https://api.groq.com/openai/v1/chat/completions"

    // MARK: - Payload (OpenAI chat format)

    private struct ImageUrl: Encodable {
        var url: String // "data:<mime>;base64,<b64>"
    }

    private struct ContentPart: Encodable {
        var type: String // "text" | "image_url"
        var text: String?
        var image_url: ImageUrl?

        enum CodingKeys: String, CodingKey { case type, text, image_url }
    }

    private struct Message: Encodable {
        var role: String // "system" | "user" | "assistant"
        var content: Content
    }

    /// content is either a plain string or an array of parts.
    private enum Content: Encodable {
        case text(String)
        case parts([ContentPart])

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .text(let s): try c.encode(s)
            case .parts(let p): try c.encode(p)
            }
        }
    }

    private struct ChatRequest: Encodable {
        var model: String
        var messages: [Message]
        var max_tokens: Int = 2048
        var temperature: Double = 0.7
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { var content: String? }
            var message: Message?
        }
        struct ApiError: Decodable {
            var message: String?
            var code: String?
        }
        var choices: [Choice]?
        var error: ApiError?
    }

    // MARK: - Public API

    /// Send a text prompt. `usePremiumKey=false` → Secrets.groqFreeKey,
    /// `true` → Secrets.groqPremiumKey. Returns plain answer text.
    /// `history`: [(role, text)] — roles "user"/"assistant" map directly.
    /// Primary model is tried first; on 404 → fallback model tried once.
    static func sendText(_ prompt: String,
                         history: [(role: String, text: String)] = [],
                         systemInstruction: String? = nil,
                         usePremiumKey: Bool = false) async throws -> String {
        let key = pickKey(usePremiumKey: usePremiumKey)
        guard !key.isEmpty else { throw GroqError.unauthorized }
        var messages: [Message] = []
        if let sys = systemInstruction, !sys.isEmpty {
            messages.append(Message(role: "system", content: .text(sys)))
        }
        for h in history {
            messages.append(Message(role: h.role, content: .text(h.text)))
        }
        messages.append(Message(role: "user", content: .text(prompt)))
        do {
            do {
                return try await requestOnce(key: key, model: primaryModel, messages: messages)
            } catch GroqError.modelNotFound {
                // 404 → try fallback model once, then done (success or final error).
                return try await requestOnce(key: key, model: fallbackModel, messages: messages)
            }
        } catch GroqError.modelNotFound {
            // Both models 404 → flag the key used so the message points correctly.
            throw GroqError.modelNotFound(usingPremiumKey: usePremiumKey)
        }
    }

    /// Send prompt + images (JPEG/PNG bytes). `images`: (data, mimeType),
    /// e.g. (jpegData, "image/jpeg"). Base64 is encoded here — pass raw
    /// bytes, without the `data:` prefix.
    static func sendWithImages(_ prompt: String,
                               images: [(data: Data, mimeType: String)],
                               history: [(role: String, text: String)] = [],
                               systemInstruction: String? = nil,
                               usePremiumKey: Bool = false) async throws -> String {
        let key = pickKey(usePremiumKey: usePremiumKey)
        guard !key.isEmpty else { throw GroqError.unauthorized }
        var messages: [Message] = []
        if let sys = systemInstruction, !sys.isEmpty {
            messages.append(Message(role: "system", content: .text(sys)))
        }
        for h in history {
            messages.append(Message(role: h.role, content: .text(h.text)))
        }
        var parts: [ContentPart] = [
            ContentPart(type: "text",
                        text: prompt.isEmpty ? "Describe this image." : prompt,
                        image_url: nil)
        ]
        for img in images {
            let dataUrl = "data:\(img.mimeType);base64,\(img.data.base64EncodedString())"
            parts.append(ContentPart(type: "image_url", text: nil,
                                     image_url: ImageUrl(url: dataUrl)))
        }
        messages.append(Message(role: "user", content: .parts(parts)))
        do {
            return try await requestOnce(key: key, model: visionModel, messages: messages)
        } catch GroqError.modelNotFound {
            // Vision model missing — flag the key used so the message points correctly.
            // (No text-model fallback: it cannot see images, so retrying would lie.)
            throw GroqError.modelNotFound(usingPremiumKey: usePremiumKey)
        }
    }

    // MARK: - Internal

    /// Pick the EMBEDDED key. NO format/length validation — just check empty.
    private static func pickKey(usePremiumKey: Bool) -> String {
        usePremiumKey ? Secrets.groqPremiumKey : Secrets.groqFreeKey
    }

    /// One HTTP request. Retry 1x ONLY for transient network errors.
    /// 401/403/429/404 are NOT retried — they become typed GroqErrors directly.
    private static func requestOnce(key: String, model: String,
                                    messages: [Message]) async throws -> String {
        let url = URL(string: endpoint)!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let body = ChatRequest(model: model, messages: messages)
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // Retry once for network errors, then hand over as .network.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                (data, response) = try await URLSession.shared.data(for: req)
            } catch {
                throw GroqError.network(error)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        switch status {
        case 200:
            break
        case 401, 403:
            throw GroqError.unauthorized
        case 404:
            throw GroqError.modelNotFound()
        case 429:
            throw GroqError.quotaExceeded
        case 400 where bodyText.lowercased().contains("model"):
            // Groq returns 400 (not 404) for unknown/decommissioned models.
            throw GroqError.modelNotFound()
        default:
            throw GroqError.invalidResponse("HTTP \(status)\n\(bodyText)")
        }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            if let apiErr = decoded.error {
                // 200 body but error envelope (rare) — map by message.
                let msg = (apiErr.message ?? "").lowercased()
                if msg.contains("model") { throw GroqError.modelNotFound() }
                throw GroqError.invalidResponse(apiErr.message ?? "unknown error")
            }
            let text = decoded.choices?.first?.message?.content ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GroqError.invalidResponse("empty choices")
            }
            return text
        } catch let e as GroqError {
            throw e
        } catch {
            throw GroqError.invalidResponse("decode: \(error.localizedDescription)")
        }
    }
}
