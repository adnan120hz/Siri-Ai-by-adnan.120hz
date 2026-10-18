import Foundation

// MARK: - Eksekutor tools GitHub untuk AI agent.
// Dipanggil dari ChatViewModel saat model mengembalikan tool_calls.
// Token diambil dari Keychain (menu Konektivitas) — tidak pernah lewat chat.

enum GitHubAgent {
    /// Batas iterasi tool loop per satu pesan user.
    static let maxIterations = 6

    /// Jalankan satu tool call, kembalikan teks hasil untuk dimasukkan
    /// sebagai pesan "tool" ke model.
    static func execute(name: String, arguments: String) async -> String {
        guard let token = GitHubStore.load(), !token.isEmpty else {
            return "GitHub is not connected on this phone. Tell the user to open Settings → Connectivity → GitHub."
        }
        let args = parseArgs(arguments)
        do {
            switch name {
            case "github_list_repos":
                return try await listRepos(token: token)
            case "github_list_files":
                guard let repo = args["repo"], !repo.isEmpty else {
                    return "Parameter 'repo' is required (format 'owner/name')."
                }
                return try await listFiles(token: token, repo: repo,
                                           prefix: args["path_prefix"])
            case "github_read_file":
                guard let repo = args["repo"], !repo.isEmpty,
                      let path = args["path"], !path.isEmpty else {
                    return "Parameters 'repo' and 'path' are required."
                }
                return try await readFile(token: token, repo: repo, path: path)
            case "github_write_file":
                guard let repo = args["repo"], !repo.isEmpty,
                      let path = args["path"], !path.isEmpty,
                      let content = args["content"] else {
                    return "Parameters 'repo', 'path', and 'content' are required."
                }
                let message: String = {
                    if let m = args["message"], !m.isEmpty { return m }
                    return "Update \(path) via ai adnan.120hz"
                }()
                return try await writeFile(token: token, repo: repo, path: path,
                                           content: content, message: message)
            case "github_delete_file":
                guard let repo = args["repo"], !repo.isEmpty,
                      let path = args["path"], !path.isEmpty else {
                    return "Parameters 'repo' and 'path' are required."
                }
                let delMessage: String = {
                    if let m = args["message"], !m.isEmpty { return m }
                    return "Delete \(path) via ai adnan.120hz"
                }()
                return try await deleteFile(token: token, repo: repo, path: path,
                                            message: delMessage)
            default:
                return "Unknown tool: \(name)."
            }
        } catch {
            return "GitHub error: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    // MARK: - Implementasi tools

    private static func listRepos(token: String) async throws -> String {
        let repos = try await GitHubClient.repos(token: token)
        guard !repos.isEmpty else { return "No repositories found." }
        let lines = repos.prefix(60).map { r in
            let lock = r.private ? "🔒" : "🌐"
            let desc = (r.description ?? "").prefix(80)
            return "\(lock) \(r.full_name) — \(desc)"
        }
        var out = lines.joined(separator: "\n")
        if repos.count > 60 { out += "\n…dan \(repos.count - 60) lainnya." }
        return out
    }

    private static func defaultBranch(token: String, repo: String) async throws -> String {
        let repos = try await GitHubClient.repos(token: token)
        if let r = repos.first(where: { $0.full_name.lowercased() == repo.lowercased() }) {
            return r.default_branch
        }
        // Repo tidak ada di daftar (mis. repo orang lain / typo) → coba "main".
        return "main"
    }

    private static func listFiles(token: String, repo: String, prefix: String?) async throws -> String {
        let branch = try await defaultBranch(token: token, repo: repo)
        let entries = try await GitHubClient.tree(token: token, repo: repo, branch: branch)
        var paths = entries.map(\.path)
        if let p = prefix, !p.isEmpty {
            paths = paths.filter { $0.hasPrefix(p) }
        }
        guard !paths.isEmpty else { return "No files found in \(repo)." }
        let shown = paths.prefix(120).joined(separator: "\n")
        var out = "File di \(repo) (branch \(branch)):\n\(shown)"
        if paths.count > 120 { out += "\n…dan \(paths.count - 120) file lainnya." }
        return out
    }

    private static func readFile(token: String, repo: String, path: String) async throws -> String {
        let branch = try await defaultBranch(token: token, repo: repo)
        let text = try await GitHubClient.rawFile(token: token, repo: repo,
                                                  branch: branch, path: path)
        return "Isi \(path) @ \(repo):\n\(text.prefix(8000))"
    }

    /// Batas Contents API: file >1MB tidak bisa dikelola lewat endpoint ini.
    private static let maxWriteBytes = 900_000

    private static func writeFile(token: String, repo: String, path: String,
                                  content: String, message: String) async throws -> String {
        guard content.utf8.count <= maxWriteBytes else {
            return "File too large (\(content.utf8.count) bytes, ~900KB limit for Contents API). " +
                "Split into multiple files or edit manually."
        }
        // Kalau file sudah ada → butuh SHA untuk update; kalau 404 → buat baru.
        var sha: String? = nil
        var isNew = true
        do {
            sha = try await GitHubClient.getFileSHA(token: token, repo: repo, path: path)
            isNew = false
        } catch GitHubError.notFound {
            isNew = true
        }
        let commit = try await GitHubClient.writeFile(token: token, repo: repo, path: path,
                                                      content: content, message: message,
                                                      sha: sha)
        let aksi = isNew ? "dibuat" : "diupdate"
        return "OK: \(path) \(aksi) di \(repo) (commit \(commit.prefix(7)))."
    }

    private static func deleteFile(token: String, repo: String, path: String,
                                   message: String) async throws -> String {
        let sha: String
        do {
            sha = try await GitHubClient.getFileSHA(token: token, repo: repo, path: path)
        } catch GitHubError.notFound {
            return "File \(path) not found in \(repo) — nothing deleted."
        }
        let commit = try await GitHubClient.deleteFile(token: token, repo: repo, path: path,
                                                       sha: sha, message: message)
        return "OK: \(path) deleted from \(repo) (commit \(commit.prefix(7)))."
    }

    // MARK: - Util

    private static func parseArgs(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
        }
        return out
    }
}
