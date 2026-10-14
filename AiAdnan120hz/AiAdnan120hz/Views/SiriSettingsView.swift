import SwiftUI
import SwiftData

// MARK: - Settings (dari hamburger di layar history):
// model picker, API key dual provider, voice, tampilan, storage 25GB, ingatan, obrolan.

struct SiriSettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var loadingModels = false
    @State private var modelsMessage: String?
    @State private var storageText = "Menghitung…"
    @State private var storageRatio: Double = 0
    @State private var showAPIKey = false
    @State private var showConversations = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Penyedia AI")) {
                    Picker("Provider", selection: $appState.activeProvider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appState.activeProvider) { _, _ in
                        appState.refreshKeyStatus()
                        reloadModels()
                    }
                    HStack {
                        Image(systemName: appState.hasAPIKey ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.hasAPIKey ? .green : .red)
                        Text(appState.hasAPIKey ? "Key \(appState.activeProvider.title): \(appState.keyMasked)" : "Key \(appState.activeProvider.title) belum dipasang")
                            .font(.subheadline)
                    }
                    Button("Kelola API Key") { showAPIKey = true }
                }

                Section(header: Text("Model")) {
                    if appState.availableModels.isEmpty {
                        Text("Daftar model kosong. Muat ulang untuk mengambil dari \(appState.activeProvider.title).")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Model", selection: $appState.defaultModelId) {
                            ForEach(appState.availableModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                    }
                    Button(loadingModels ? "Memuat…" : "Muat ulang daftar model") {
                        reloadModels()
                    }
                    .disabled(loadingModels)
                    if let modelsMessage {
                        Text(modelsMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Suara")) {
                    Toggle("Bacakan respons AI", isOn: $appState.autoSpeak)
                    Text("Kalau aktif, jawaban AI dibacakan dengan suara setelah selesai (text-to-speech beneran). Ketuk tombol mic di layar utama untuk bicara (speech-to-text beneran).")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section(header: Text("Tampilan")) {
                    Picker("Mode", selection: $appState.appearanceMode) {
                        Text("Sistem").tag("system")
                        Text("Gelap").tag("dark")
                        Text("Terang").tag("light")
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Penyimpanan lokal")) {
                    ProgressView(value: storageRatio)
                    Text("\(storageText) / 25 GB")
                        .font(.footnote).foregroundStyle(.secondary)
                    if storageRatio >= StorageQuota.warnThreshold {
                        Text("Hampir penuh (≥90%). Hapus obrolan lama untuk mengosongkan ruang.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section(header: Text("Ingatan")) {
                    Toggle("Ingatan AI", isOn: $appState.memoryEnabled)
                    Text("Ingatan 100% lokal di HP ini (bukan cloud).")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !facts.isEmpty {
                        Text("\(facts.count) fakta tersimpan")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Hapus semua ingatan", role: .destructive) {
                        for f in facts { context.delete(f) }
                        try? context.save()
                    }
                }

                Section {
                    Button("Semua obrolan (\(conversations.count))") { showConversations = true }
                    NavigationLink(destination: ConnectivityView()) {
                        Label("Konektivitas", systemImage: "link")
                    }
                }

                Section(header: Text("Tentang")) {
                    Text("Siri Ai 1.0 — chat AI lewat API key milikmu (APInex / NVIDIA NIM). Tanpa akun, tanpa login.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pengaturan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
            .sheet(isPresented: $showAPIKey) { APIKeyView() }
            .sheet(isPresented: $showConversations) {
                ConversationListSheet()
            }
            .onAppear { refreshStorage() }
        }
    }

    private func reloadModels() {
        let provider = appState.activeProvider
        guard let key = KeychainStore.load(for: provider), !key.isEmpty else {
            modelsMessage = APIError.noKey.localizedDescription
            return
        }
        loadingModels = true
        modelsMessage = nil
        Task { @MainActor in
            do {
                let models = try await AIClient.fetchAllowedModels(apiKey: key, provider: provider)
                await MainActor.run {
                    appState.availableModels = models
                    if !models.contains(appState.defaultModelId) {
                        // Prefer default provider kalau ada di list.
                        if models.contains(provider.defaultModel) {
                            appState.defaultModelId = provider.defaultModel
                        } else {
                            appState.defaultModelId = models.first ?? provider.defaultModel
                        }
                    }
                    modelsMessage = "\(models.count) model ditemukan."
                    loadingModels = false
                }
            } catch {
                await MainActor.run {
                    modelsMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    loadingModels = false
                }
            }
        }
    }

    private func refreshStorage() {
        Task.detached {
            let used = StorageQuota.usedBytes()
            let ratio = Double(used) / Double(StorageQuota.capBytes)
            await MainActor.run {
                storageText = StorageQuota.formatted(used)
                storageRatio = min(1.0, ratio)
            }
        }
    }
}

// MARK: - Daftar obrolan sederhana di dalam settings.

struct ConversationListSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    var body: some View {
        NavigationStack {
            List {
                ForEach(conversations) { convo in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(convo.title.isEmpty ? "Obrolan baru" : convo.title)
                            .font(.headline)
                        Text(convo.updatedAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(conversations[i]) }
                    try? context.save()
                }
            }
            .navigationTitle("Semua obrolan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
        }
    }
}
