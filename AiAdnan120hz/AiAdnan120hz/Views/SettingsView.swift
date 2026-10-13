import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]

    @State private var loadingModels = false
    @State private var modelsMessage: String?
    @State private var storageText = "Menghitung…"
    @State private var storageRatio: Double = 0
    @State private var showAPIKey = false
    @AppStorage("altIconName") private var altIconName: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("API Key")) {
                    HStack {
                        Image(systemName: appState.hasAPIKey ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.hasAPIKey ? .green : .red)
                        Text(appState.hasAPIKey ? "Terpasang: \(appState.keyMasked)" : "Belum dipasang")
                    }
                    Button(appState.hasAPIKey ? "Ganti / Hapus Key" : "Pasang Key") {
                        showAPIKey = true
                    }
                }

                Section(header: Text("Model")) {
                    HStack {
                        Text("Akun:")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(appState.accountTier == .paid ? "Paid account" : appState.accountTier == .free ? "Free account" : "Belum terdeteksi")
                            .font(.subheadline).bold()
                            .foregroundStyle(appState.accountTier == .paid ? .green : appState.accountTier == .free ? .orange : .secondary)
                        Spacer()
                        if appState.accountTier == .free {
                            Text("Model paid terkunci")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if appState.availableModels.isEmpty {
                        Text("Daftar model kosong. Muat ulang untuk mengambil dari apinex.bond.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Model bawaan", selection: $appState.defaultModelId) {
                            ForEach(appState.availableModels, id: \.self) { m in
                                let locked = appState.accountTier == .free && !APInexClient.isFreeModel(m)
                                HStack {
                                    Text(m)
                                    if locked {
                                        Text("· Paid").foregroundStyle(.secondary)
                                    }
                                }
                                .tag(m)
                                .disabled(locked)
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

                Section(header: Text("Tampilan")) {
                    Picker("Mode", selection: $appState.appearanceMode) {
                        Text("Sistem").tag("system")
                        Text("Gelap").tag("dark")
                        Text("Terang").tag("light")
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Kuota Token")) {
                    TokenUsageView()
                }

                Section {
                    NavigationLink(destination: ConnectivityView()) {
                        Label("Konektivitas", systemImage: "link")
                    }
                    Text("Hubungkan GitHub (akses repo sebagai source) dan simpan link media sosial.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section(header: Text("Ingatan")) {
                    Toggle("Ingatan AI", isOn: $appState.memoryEnabled)
                    Text("Ingatan 100% lokal di HP ini (bukan cloud). AI merangkum obrolan dan menyimpan fakta tentangmu untuk dipakai di prompt berikutnya.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !facts.isEmpty {
                        NavigationLink(destination:
                            List {
                                ForEach(facts) { f in
                                    VStack(alignment: .leading) {
                                        Text(f.fact).font(.subheadline)
                                        Text(f.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .onDelete { offsets in
                                    for i in offsets { context.delete(facts[i]) }
                                    try? context.save()
                                }
                            }
                            .navigationTitle("Ingatan AI")
                        ) {
                            Text("Lihat ingatan (\(facts.count))")
                        }
                    }
                    Button("Hapus semua ingatan", role: .destructive) {
                        for f in facts { context.delete(f) }
                        try? context.save()
                    }
                    .disabled(facts.isEmpty)
                } header: {
                    Text("Ingatan")
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

                Section(header: Text("Icon aplikasi")) {
                    iconRow(name: "", title: "Utama — Navy 120hz", file: nil)
                    iconRow(name: "IconSwiss", title: "Hitam — Swiss", file: "IconSwiss@3x")
                    iconRow(name: "IconCream", title: "Krem — Editorial", file: "IconCream@3x")
                    Text("Mengganti icon butuh konfirmasi sistem iOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section(header: Text("Tentang")) {
                    Text("Siri Ai 1.0 — chat AI lewat API key apinex.bond milikmu. Tanpa akun, tanpa login.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Mode Suara = loop STT → AI → TTS on-device, bukan realtime duplex.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Pengaturan")
            .sheet(isPresented: $showAPIKey) { APIKeyView() }
            .onAppear { refreshStorage() }
        }
    }

    @ViewBuilder
    private func iconRow(name: String, title: String, file: String?) -> some View {
        Button {
            Task { @MainActor in setIcon(name.isEmpty ? nil : name) }
        } label: {
            HStack {
                if let file, let ui = UIImage(named: file) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue)
                        .frame(width: 44, height: 44)
                        .overlay(Text("Ai").font(.headline).foregroundStyle(.white))
                }
                Text(title).foregroundStyle(.primary)
                Spacer()
                if altIconName == name {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @MainActor
    private func setIcon(_ name: String?) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            if error == nil {
                Task { @MainActor in altIconName = name ?? "" }
            }
        }
    }

    private func reloadModels() {
        guard let key = KeychainStore.load(), !key.isEmpty else {
            modelsMessage = APIError.noKey.localizedDescription
            return
        }
        loadingModels = true
        modelsMessage = nil
        Task { @MainActor in
            do {
                let models = try await APInexClient.fetchModels(apiKey: key)
                await MainActor.run {
                    appState.availableModels = models
                    if appState.defaultModelId.isEmpty, let first = models.first {
                        appState.defaultModelId = first
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
