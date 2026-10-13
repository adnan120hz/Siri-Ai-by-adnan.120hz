import SwiftUI

// MARK: - Layar API key: tempel → simpan (Keychain) / hapus. Tanpa akun, tanpa login.

struct APIKeyView: View {
    @EnvironmentObject var appState: AppState
    @State private var keyInput = ""
    @State private var message: String?
    @State private var isError = false
    @State private var isValidating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key apinex.bond")
                            .font(.headline)
                        Text("Tempel API key kamu dari apinex.bond. Key hanya disimpan di Keychain HP ini — tidak dikirim ke mana pun selain api.apinex.bond saat chat.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    SecureField("Tempel API key di sini", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(isValidating ? "Memeriksa…" : "Simpan Key") { Task { @MainActor in save() } }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
                }

                if appState.hasAPIKey {
                    Section(header: Text("Status")) {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Key terpasang: \(appState.keyMasked)")
                                .font(.subheadline)
                        }
                        Button("Hapus Key", role: .destructive) { Task { @MainActor in remove() } }
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
        }
    }

    @MainActor
    private func save() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        // Simpan dulu ke Keychain, lalu VALIDASI ke server: kalau key salah /
        // revoked, user langsung tahu alasannya saat ini juga — bukan pas chat.
        guard KeychainStore.save(key) else {
            message = "Gagal menyimpan ke Keychain."
            isError = true
            return
        }
        keyInput = ""
        appState.refreshKeyStatus()
        isValidating = true
        message = "Key tersimpan. Memeriksa ke server…"
        isError = false
        Task { @MainActor in
            do {
                let models = try await APInexClient.fetchModels(apiKey: key)
                // Deteksi tier: probe model paid termurah.
                var tier = APInexClient.AccountTier.unknown
                if let paid = models.first(where: { !APInexClient.isFreeModel($0) }) {
                    tier = (try? await APInexClient.detectTier(apiKey: key, paidModelId: paid)) ?? .unknown
                } else {
                    // Tidak ada model paid di daftar → anggap free.
                    tier = .free
                }
                await MainActor.run {
                    appState.availableModels = models
                    appState.accountTier = tier
                    // Model bawaan lama bisa jadi tidak ada di akun key baru,
                    // atau model paid yang sekarang ke-lock → reset.
                    let cur = appState.defaultModelId
                    let curLocked = tier == .free && !cur.isEmpty && !APInexClient.isFreeModel(cur)
                    if !models.contains(cur) || curLocked {
                        appState.defaultModelId = models.first(where: { APInexClient.isFreeModel($0) }) ?? models.first ?? ""
                    }
                    let tierText = tier == .paid ? "Paid" : tier == .free ? "Free" : "?"
                    message = "Key valid (\(tierText)) — \(models.count) model tersedia."
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
        if KeychainStore.remove() {
            appState.refreshKeyStatus()
            appState.availableModels = []
            appState.defaultModelId = ""
            appState.accountTier = .unknown
            message = "Key dihapus."
            isError = false
        } else {
            message = "Gagal menghapus key."
            isError = true
        }
    }
}
