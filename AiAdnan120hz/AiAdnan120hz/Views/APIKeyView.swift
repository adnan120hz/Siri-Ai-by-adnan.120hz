import SwiftUI

// MARK: - Layar API key: tempel → simpan (Keychain) / hapus. Tanpa akun, tanpa login.

struct APIKeyView: View {
    @EnvironmentObject var appState: AppState
    @State private var keyInput = ""
    @State private var message: String?
    @State private var isError = false

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

                    Button("Simpan Key") { Task { @MainActor in save() } }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if appState.hasAPIKey {
                    Section("Status") {
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
        if KeychainStore.save(key) {
            keyInput = ""
            appState.refreshKeyStatus()
            message = "Key tersimpan di Keychain."
            isError = false
        } else {
            message = "Gagal menyimpan ke Keychain."
            isError = true
        }
    }

    @MainActor
    private func remove() {
        if KeychainStore.remove() {
            appState.refreshKeyStatus()
            appState.availableModels = []
            message = "Key dihapus."
            isError = false
        } else {
            message = "Gagal menghapus key."
            isError = true
        }
    }
}
