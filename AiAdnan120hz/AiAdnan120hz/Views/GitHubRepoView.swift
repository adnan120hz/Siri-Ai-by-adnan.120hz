import SwiftUI
import SwiftData

// MARK: - Jelajahi file repo GitHub → simpan sebagai Source Web.

struct GitHubRepoView: View {
    let repo: GitHubClient.Repo
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var files: [GitHubClient.Tree.Entry] = []
    @State private var loading = true
    @State private var search = ""
    @State private var message: String?
    @State private var isError = false
    @State private var savingPath: String?

    /// Ekstensi file kode/teks yang relevan sebagai source.
    private let codeExts: Set<String> = ["swift", "py", "js", "ts", "tsx", "jsx", "java", "kt",
                                        "go", "rs", "c", "h", "cpp", "cs", "rb", "php", "md",
                                        "txt", "json", "yml", "yaml", "toml", "sh", "sql"]

    var body: some View {
        List {
            if loading {
                ProgressView("Memuat file…")
            } else {
                TextField("Cari file…", text: $search)
                ForEach(filtered) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.path).font(.subheadline).lineLimit(2)
                        }
                        Spacer()
                        if savingPath == entry.path {
                            ProgressView()
                        } else {
                            Button {
                                Task { @MainActor in await saveAsSource(entry) }
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                    }
                }
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(isError ? .red : .green)
            }
        }
        .navigationTitle(repo.full_name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Tutup") { dismiss() }
            }
        }
        .onAppear { Task { @MainActor in await loadTree() } }
    }

    private var filtered: [GitHubClient.Tree.Entry] {
        var list = files.filter { codeExts.contains(($0.path as NSString).pathExtension.lowercased()) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.path.lowercased().contains(q) }
        }
        return Array(list.prefix(500))
    }

    @MainActor
    private func loadTree() async {
        guard let token = GitHubStore.load() else {
            message = "Token GitHub hilang."
            isError = true
            loading = false
            return
        }
        do {
            files = try await GitHubClient.tree(token: token, repo: repo.full_name, branch: repo.default_branch)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
        loading = false
    }

    @MainActor
    private func saveAsSource(_ entry: GitHubClient.Tree.Entry) async {
        guard let token = GitHubStore.load() else { return }
        savingPath = entry.path
        message = nil
        isError = false
        do {
            let text = try await GitHubClient.rawFile(token: token, repo: repo.full_name,
                                                      branch: repo.default_branch, path: entry.path)
            let url = "https://github.com/\(repo.full_name)/blob/\(repo.default_branch)/\(entry.path)"
            let ws = WebSource(url: url, title: "\(repo.full_name): \(entry.path)", extractedText: text)
            context.insert(ws)
            try? context.save()
            message = "Tersimpan ke Source Web: \(entry.path)"
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isError = true
        }
        savingPath = nil
    }
}

extension GitHubClient.Tree.Entry: Identifiable {
    var id: String { path }
}
