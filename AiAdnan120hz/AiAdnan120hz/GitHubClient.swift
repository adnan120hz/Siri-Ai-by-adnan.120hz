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
    static let apiBase = URL(string: "https://api.github.com")!

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

    private static func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var req = URLRequest(url: apiBase.appendingPathComponent(path))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(APInexClient.userAgent, forHTTPHeaderField: "User-Agent")
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
        try await get("user", token: token)
    }

    static func repos(token: String) async throws -> [Repo] {
        do {
            return try await get("user/repos?per_page=100&sort=updated", token: token)
        } catch GitHubError.http(let s, _) where s == 404 {
            // Fine-grained PAT tanpa akses repository → GitHub balas 404 (bukan 403).
            throw GitHubError.noRepoAccess
        }
    }

    static func tree(token: String, repo: String, branch: String) async throws -> [Tree.Entry] {
        do {
            let t: Tree = try await get("repos/\(repo)/git/trees/\(branch)?recursive=1", token: token)
            return t.tree.filter { $0.type == "blob" }
        } catch GitHubError.http(let s, _) where s == 404 {
            throw GitHubError.notFound("repo \(repo)")
        }
    }

    /// Ambil isi file mentah via raw.githubusercontent.com
    static func rawFile(token: String, repo: String, branch: String, path: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/\(path)")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(APInexClient.userAgent, forHTTPHeaderField: "User-Agent")
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
