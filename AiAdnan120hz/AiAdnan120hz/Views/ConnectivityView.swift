import SwiftUI
import SwiftData

// MARK: - Menu "Konektivitas": GitHub (PAT) + link media sosial.

struct ConnectivityView: View {
    @Environment(\.modelContext) private var context

    @State private var ghTokenInput = ""
    @State private var ghUser: String?
    @State private var ghRepos: [GitHubClient.Repo] = []
    @State private var ghLoading = false
    @State private var ghMessage: String?
    @State private var ghError = false
    @State private var repoSearch = ""
    @State private var selectedRepo: GitHubClient.Repo?

    @State private var socials: [SocialLink] = SocialStore.load()
    @State private var newSocialName = ""
    @State private var newSocialURL = ""

    var body: some View {
        List {
            // ---- GitHub ----
            Section {
                if let user = ghUser {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Terhubung: @\(user)").font(.subheadline)
                        Spacer()
                        Button("Putuskan", role: .destructive) { disconnectGitHub() }
                            .font(.subheadline)
                    }
                } else {
                    SecureField("Personal Access Token (github.com/settings/tokens)", text: $ghTokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(ghLoading ? "Menghubungkan…" : "Hubungkan GitHub") {
                        Task { @MainActor in await connectGitHub() }
                    }
                    .disabled(ghTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ghLoading)
                }
                if let ghMessage {
                    Text(ghMessage).font(.footnote).foregroundStyle(ghError ? .red : .green)
                }
            } header: {
                Text("GitHub")
            } footer: {
                Text("Butuh scope \"repo\" untuk repo privat. Token hanya disimpan di Keychain HP ini.")
            }

            if ghUser != nil {
                Section {
                    TextField("Cari repo…", text: $repoSearch)
                    if ghLoading && ghRepos.isEmpty {
                        ProgressView("Memuat repo…")
                    }
                    ForEach(filteredRepos) { repo in
                        Button {
                            selectedRepo = repo
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(repo.full_name).font(.subheadline)
                                    if repo.private {
                                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                if let d = repo.description, !d.isEmpty {
                                    Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Repository (\(filteredRepos.count))")
                } footer: {
                    Text("Ketuk repo untuk jelajahi file dan simpan sebagai Source Web.")
                }
            }

            // ---- Media sosial ----
            Section {
                ForEach(socials) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.name).font(.subheadline)
                            Text(s.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let url = URL(string: s.url), UIApplication.shared.canOpenURL(url) {
                            Button {
                                UIApplication.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    socials.remove(atOffsets: offsets)
                    SocialStore.save(socials)
                }
                HStack {
                    TextField("Nama (mis. TikTok)", text: $newSocialName)
                    TextField("URL", text: $newSocialURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        addSocial()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newSocialName.trimmingCharacters(in: .whitespaces).isEmpty
                              || newSocialURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Media Sosial")
            } footer: {
                Text("Link cepat ke akun media sosialmu. Geser kiri untuk menghapus.")
            }
        }
        .navigationTitle("Konektivitas")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedRepo) { repo in
            NavigationStack { GitHubRepoView(repo: repo) }
        }
        .onAppear { Task { @MainActor in await refreshGitHub() } }
    }

    private var filteredRepos: [GitHubClient.Repo] {
        let q = repoSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ghRepos }
        return ghRepos.filter { $0.full_name.lowercased().contains(q) }
    }

    @MainActor
    private func connectGitHub() async {
        let token = ghTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        ghLoading = true
        ghMessage = nil
        ghError = false
        do {
            let user = try await GitHubClient.validate(token: token)
            GitHubStore.save(token)
            ghTokenInput = ""
            ghUser = user.login
            ghMessage = "Terhubung sebagai @\(user.login)."
            await loadRepos(token: token)
        } catch {
            ghMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ghError = true
        }
        ghLoading = false
    }

    @MainActor
    private func refreshGitHub() async {
        guard let token = GitHubStore.load() else { return }
        ghLoading = true
        do {
            let user = try await GitHubClient.validate(token: token)
            ghUser = user.login
            await loadRepos(token: token)
        } catch {
            // Token basi → putuskan diam-diam, user hubungkan ulang.
            ghUser = nil
            ghRepos = []
        }
        ghLoading = false
    }

    @MainActor
    private func loadRepos(token: String) async {
        do {
            ghRepos = try await GitHubClient.repos(token: token)
        } catch {
            ghMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            ghError = true
        }
    }

    private func disconnectGitHub() {
        GitHubStore.remove()
        ghUser = nil
        ghRepos = []
        ghMessage = "GitHub diputus."
        ghError = false
    }

    private func addSocial() {
        var url = newSocialURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        let name = newSocialName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !url.isEmpty else { return }
        socials.append(SocialLink(name: name, url: url))
        SocialStore.save(socials)
        newSocialName = ""
        newSocialURL = ""
    }
}
