import SwiftUI

// MARK: - Layar API key dual provider: APInex / NVIDIA NIM.
// Cukup isi SATU. Key disimpan terpisah per provider di Keychain. Tanpa akun, tanpa login.

struct APIKeyView: View {
    @EnvironmentObject var appState: AppState
    @State private var provider: AIProvider = .apinex
    @State private var keyInput = ""
    @State private var message: String?
    @State private var isError = false
    @State private var isValidating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Penyedia", selection: $provider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("Cukup isi satu — tidak harus dua-duanya.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key \(provider.title)")
                            .font(.headline)
                        Text(provider.keyHelp)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(provider.keyDestinationNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link(provider.keyGetLinkText, destination: provider.keyGetURL)
                            .font(.footnote)
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 4)

                    SecureField("Tempel API key di sini", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(isValidating ? "Memeriksa…" : "Simpan Key") { Task { @MainActor in save() } }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
                }

                Section(header: Text("Status per provider")) {
                    ForEach(AIProvider.allCases) { p in
                        HStack {
                            Image(systemName: appState.hasKey(for: p) ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(appState.hasKey(for: p) ? .green : .red)
                            Text(p.title)
                                .font(.subheadline)
                            Spacer()
                            if appState.hasKey(for: p) {
                                Text(appState.maskedKey(for: p))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { provider = p }
                    }
                    if appState.hasKey(for: provider) {
                        Button("Hapus Key \(provider.title)", role: .destructive) { Task { @MainActor in remove() } }
                    }
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }

                Section {
                    Text("Aplikasi ini tidak punya sistem akun/login. Satu-satunya kredensial adalah API key milikmu sendiri.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(appState.hasAPIKey ? "API Key" : "Selamat datang")
            .onAppear { provider = appState.activeProvider }
        }
    }

    @MainActor
    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Simpan dulu ke Keychain, lalu VALIDASI ke server: kalau key salah /
        // revoked, user langsung tahu alasannya saat ini juga — bukan pas chat.
        guard KeychainStore.save(key, for: provider) else {
            message = "Gagal menyimpan ke Keychain."
            isError = true
            return
        }
        keyInput = ""
        appState.activeProvider = provider
        appState.refreshKeyStatus()
        isValidating = true
        message = "Key tersimpan. Memeriksa ke server…"
        isError = false
        Task { @MainActor in
            do {
                let models = try await AIClient.fetchAllowedModels(apiKey: key, provider: provider)
                await MainActor.run {
                    appState.availableModels = models
                    let cur = appState.defaultModelId
                    if !provider.allowsModel(cur) || !models.contains(cur) {
                        // Prefer default provider kalau ada di list (mis. NVIDIA:
                        // z-ai/glm-5-3-flash gratis), baru fallback ke models.first.
                        // Ini mencegah model basi yang 404 (tidak ter-deploy di akun).
                        if models.contains(provider.defaultModel) {
                            appState.defaultModelId = provider.defaultModel
                        } else {
                            appState.defaultModelId = models.first ?? provider.defaultModel
                        }
                    }
                    message = "Key valid — \(models.count) model tersedia."
                    isError = false
                    isValidating = false
                }
            } catch {
                await MainActor.run {
                    let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    message = "Key tersimpan, tapi server menolak: \(desc)"
                    isError = true
                    isValidating = false
                }
            }
        }
    }

    @MainActor
    private func remove() {
        if KeychainStore.remove(for: provider) {
            appState.refreshKeyStatus()
            // Kalau key yang dihapus milik provider aktif, kosongkan daftar model.
            if provider == appState.activeProvider {
                appState.availableModels = []
                appState.defaultModelId = ""
            }
            message = "Key \(provider.title) dihapus."
            isError = false
        } else {
            message = "Gagal menghapus key."
            isError = true
        }
    }
}
