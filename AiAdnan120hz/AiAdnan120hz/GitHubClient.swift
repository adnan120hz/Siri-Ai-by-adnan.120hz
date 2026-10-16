import Foundation
import Security

// MARK: - GitHub: PAT di Keychain + API client.
// Dipakai untuk akses repo langsung sebagai source (tanpa OAuth/server).

enum GitHubStore {
    private static let service = "com.adnan120hz.aiadnan120hz.github"
    private static let account = "pat"

    static func save(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let t = String(data: data, encoding: .utf8),
              !t.isEmpty else { return nil }
        return t
    }

    static func remove() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - API client

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case network(URLError)
    case decoding(String)
    case noRepoAccess
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "Belum ada GitHub token. Hubungkan dulu."
        case .http(let s, let b):
            let short = b.count > 400 ? String(b.prefix(400)) + "…" : b
            return "GitHub HTTP \(s)\n\(short)"
        case .network(let e): return "Jaringan: \(e.localizedDescription)"
        case .decoding(let s): return "Gagal baca respons: \(s)"
        case .noRepoAccess:
            return "Token tidak punya akses repository (GitHub mengembalikan 404). " +
                "Buat token baru — classic: centang scope \"repo\"; " +
                "fine-grained: beri akses ke repository yang dibutuhkan — lalu hubungkan ulang di menu ini."
        case .notFound(let s): return "Tidak ditemukan: \(s). Periksa nama repo / path file."
        }
    }
}

struct GitHubClient {

    struct User: Decodable { var login: String; var name: String? }
    struct Repo: Decodable, Identifiable {
        var id: Int
        var full_name: String
        var description: String?
        var default_branch: String
        var `private`: Bool
    }
    struct Tree: Decodable {
        struct Entry: Decodable { var path: String; var type: String }
        var tree: [Entry]
        var truncated: Bool?
    }

    /// Bangun URL API dengan query yang di-encode benar.
    /// (appendingPathComponent meng-encode "?" sehingga query inline rusak —
    ///  bug ini sebelumnya membuat per_page/sort/recursive diabaikan server.)
    private static func apiURL(path: String, query: [String: String] = [:]) -> URL? {
        var comp = URLComponents(string: "https://api.github.com")
        comp?.path = "/" + path
        if !query.isEmpty {
            comp?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return comp?.url
    }

    private static func get<T: Decodable>(path: String, query: [String: String] = [:], token: String) async throws -> T {
        guard let url = apiURL(path: path, query: query) else {
            throw GitHubError.decoding("URL tidak valid: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(GeminiClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw GitHubError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw GitHubError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    static func validate(token: String) async throws -> User {
        try await get(path: "user", token: token)
    }

    static func repos(token: String) async throws -> [Repo] {
        do {
            return try await get(path: "user/repos",
                                 query: ["per_page": "100", "sort": "updated"],
                                 token: token)
        } catch GitHubError.http(let s, _) where s == 404 {
            // Fine-grained PAT tanpa akses repository → GitHub balas 404 (bukan 403).
            throw GitHubError.noRepoAccess
        }
    }

    static func tree(token: String, repo: String, branch: String) async throws -> [Tree.Entry] {
        do {
            let t: Tree = try await get(path: "repos/\(repo)/git/trees/\(branch)",
                                        query: ["recursive": "1"],
                                        token: token)
            return t.tree.filter { $0.type == "blob" }
        } catch GitHubError.http(let s, _) where s == 404 {
            throw GitHubError.notFound("repo \(repo)")
        }
    }

    /// Ambil isi file mentah via raw.githubusercontent.com
    static func rawFile(token: String, repo: String, branch: String, path: String) async throws -> String {
        let encodedPath = encodePath(path)
        guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(encodedPath)") else {
            throw GitHubError.decoding("Path tidak valid: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(GeminiClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 60
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            throw GitHubError.network(e)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            if status == 404 { throw GitHubError.notFound("file \(path) di \(repo)") }
            throw GitHubError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw GitHubError.decoding("File kosong / bukan teks.")
        }
        return String(text.prefix(SourceExtractor.maxChars))
    }

    // MARK: - Contents API (tulis): dipakai github.com web editor juga.

    struct ContentItem: Decodable {
        var sha: String
        var type: String?
    }

    struct ContentWriteResponse: Decodable {
        struct CommitInfo: Decodable { var sha: String? }
        var content: ContentItem?
        var commit: CommitInfo?
    }

    /// Encode tiap segmen path (spasi/karakter khusus di nama file tidak boleh merusak URL).
    private static func encodePath(_ path: String) -> String {
        path.split(separator: "/").map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }

    private static func contentsURL(repo: String, path: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(repo)/contents/\(encodePath(path))")
    }

    /// Request JSON umum untuk PUT/DELETE (dan GET tanpa body).
    private static func sendJSON<Res: Decodable>(method: String, url: URL, token: String,
                                                jsonBody: Data?,
                                                okStatuses: Set<Int>) async throws -> Res {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(GeminiClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = jsonBody
        }
        let data: Data
        let status: Int
        do {
            let (d, response) = try await URLSession.shared.data(for: req)
            data = d
            status = (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch let e as URLError {
            throw GitHubError.network(e)
        }
        guard okStatuses.contains(status) else {
            if status == 404 { throw GitHubError.notFound("path di repo") }
            if status == 409 {
                throw GitHubError.http(status, "Konflik SHA — file berubah di server. Baca ulang dulu lalu coba lagi.")
            }
            if status == 422 {
                throw GitHubError.http(status, "Validasi gagal: \(String(data: data, encoding: .utf8) ?? "")")
            }
            throw GitHubError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(Res.self, from: data)
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    /// Ambil SHA blob file — wajib untuk update/delete. Throw notFound kalau tidak ada.
    static func getFileSHA(token: String, repo: String, path: String) async throws -> String {
        guard let url = contentsURL(repo: repo, path: path) else {
            throw GitHubError.decoding("Path tidak valid: \(path)")
        }
        do {
            let item: ContentItem = try await sendJSON(method: "GET", url: url,
                                                       token: token, jsonBody: nil,
                                                       okStatuses: [200])
            return item.sha
        } catch GitHubError.notFound {
            throw GitHubError.notFound("file \(path) di \(repo)")
        }
    }

    /// Buat file baru (sha nil) atau update file (sha dari getFileSHA).
    /// Mengembalikan SHA commit. Isi dikirim sebagai base64 sesuai API.
    static func writeFile(token: String, repo: String, path: String,
                          content: String, message: String, sha: String?) async throws -> String {
        guard let url = contentsURL(repo: repo, path: path) else {
            throw GitHubError.decoding("Path tidak valid: \(path)")
        }
        struct Body: Encodable {
            var message: String
            var content: String  // base64
            var sha: String?     // nil = buat baru (key di-omit, bukan null)
            enum CodingKeys: String, CodingKey { case message, content, sha }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(message, forKey: .message)
                try c.encode(content, forKey: .content)
                try c.encodeIfPresent(sha, forKey: .sha)
            }
        }
        let body = Body(message: message,
                        content: Data(content.utf8).base64EncodedString(),
                        sha: sha)
        let bodyData = try JSONEncoder().encode(body)
        let res: ContentWriteResponse = try await sendJSON(method: "PUT", url: url,
                                                           token: token, jsonBody: bodyData,
                                                           okStatuses: [200, 201])
        return res.commit?.sha ?? res.content?.sha ?? "?"
    }

    /// Hapus file. `sha` wajib — ambil via getFileSHA dulu.
    /// Mengembalikan SHA commit.
    static func deleteFile(token: String, repo: String, path: String,
                           sha: String, message: String) async throws -> String {
        guard let url = contentsURL(repo: repo, path: path) else {
            throw GitHubError.decoding("Path tidak valid: \(path)")
        }
        struct Body: Encodable { var message: String; var sha: String }
        let bodyData = try JSONEncoder().encode(Body(message: message, sha: sha))
        let res: ContentWriteResponse = try await sendJSON(method: "DELETE", url: url,
                                                           token: token, jsonBody: bodyData,
                                                           okStatuses: [200])
        return res.commit?.sha ?? "?"
    }
}

// MARK: - Link media sosial (UserDefaults, tanpa akun)

struct SocialLink: Codable, Identifiable {
    var id: UUID
    var name: String
    var url: String

    init(name: String, url: String) {
        self.id = UUID()
        self.name = name
        self.url = url
    }
}

enum SocialStore {
    private static let key = "socialLinks"

    static func load() -> [SocialLink] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SocialLink].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SocialLink]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
