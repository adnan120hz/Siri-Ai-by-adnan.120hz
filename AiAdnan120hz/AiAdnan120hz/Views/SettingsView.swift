import SwiftUI
import SwiftData


// MARK: - Settings. Native Form.
// API key per provider (required: at least 1), model auto-detect,
// voice, appearance, 25GB storage, local memory.

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var keyInput = ""
    @State private var isValidating = false
    @State private var keyMessage: String?
    @State private var loadingModels = false
    @State private var modelsMessage: String?
    @State private var storageText = "Calculating…"
    @State private var storageRatio: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                // API key is required for the AI to work.
                if !appState.hasAPIKey {
                    Section {
                        Label("An API key is required for Siri Ai to work. Add at least one below.",
                              systemImage: "key.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }

                Section(header: Text("AI Provider")) {
                    HStack {
                        Text("APInex")
                            .font(.headline)
                        Spacer()
                    }

                    HStack(spacing: SiriTheme.s) {
                        Image(systemName: appState.hasKey(for: appState.activeProvider)
                              ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.hasKey(for: appState.activeProvider) ? .green : .red)
                        Text(appState.hasKey(for: appState.activeProvider)
                             ? "Key \(appState.activeProvider.title): \(KeychainStore.masked(KeychainStore.load(for: appState.activeProvider) ?? ""))"
                             : "No \(appState.activeProvider.title) key yet")
                            .font(.subheadline)
                    }

                    Text(appState.activeProvider.keyHelp)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // English link, per user instruction.
                    Link("Get your API key here", destination: appState.activeProvider.keyGetURL)
                        .font(.footnote)
                        .fontWeight(.semibold)

                    SecureField("Paste API key here", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack {
                        Button(isValidating ? "Checking…" : "Save Key") {
                            Task { @MainActor in await saveKey() }
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
                        if appState.hasKey(for: appState.activeProvider) {
                            Spacer()
                            Button("Remove", role: .destructive) {
                                KeychainStore.remove(for: appState.activeProvider)
                                appState.refreshKeyStatus()
                                keyMessage = nil
                            }
                        }
                    }
                    if let keyMessage {
                        Text(keyMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Model")) {
                    if appState.availableModels.isEmpty {
                        Text("No models loaded. Reload to fetch from \(appState.activeProvider.title).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Select Model", selection: $appState.defaultModelId) {
                            ForEach(appState.availableModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                    }
                    Button(loadingModels ? "Loading…" : "Reload model list") {
                        reloadModels()
                    }
                    .disabled(loadingModels)
                    if let modelsMessage {
                        Text(modelsMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Voice")) {
                    Toggle("Read AI responses aloud", isOn: $appState.autoSpeak)
                    Text("When on, AI answers are spoken after they finish (real text-to-speech). Tap the mic button on the main screen to talk (real speech-to-text).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Appearance")) {
                    Picker("Mode", selection: $appState.appearanceMode) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Local storage")) {
                    ProgressView(value: storageRatio)
                    Text("\(storageText) / 25 GB")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if storageRatio >= StorageQuota.warnThreshold {
                        Text("Almost full (≥90%). Delete old chats to free space.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section(header: Text("Memory")) {
                    Toggle("AI memory", isOn: $appState.memoryEnabled)
                    Text("Memory is 100% local on this phone (not cloud).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !facts.isEmpty {
                        Text("\(facts.count) facts stored")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button("Delete all memory", role: .destructive) {
                        for f in facts { context.delete(f) }
                        try? context.save()
                    }
                }

                Section(header: Text("About")) {
                    Text("Siri Ai — AI chat with your own API key (APInex). No account, no login.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Credit: @adnan.120hz (TikTok)", destination: URL(string: "https://www.tiktok.com/@adnan.120hz")!)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDetents([.medium, .large])
            .presentationContentInteraction(.scrolls)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                refreshStorage()
            }
        }
    }

    // MARK: - Key save + validate against the provider.

    @MainActor
    private func saveKey() async {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidating = true
        keyMessage = nil
        do {
            let p = appState.activeProvider
            let models = try await AIClient.fetchAllowedModels(apiKey: key, provider: p)
            guard KeychainStore.save(key, for: p) else {
                keyMessage = "Could not save to Keychain."
                isValidating = false
                return
            }
            appState.refreshKeyStatus()
            appState.availableModels = models
            if !models.contains(appState.defaultModelId) {
                appState.defaultModelId = models.contains(p.defaultModel)
                    ? p.defaultModel
                    : (models.first ?? p.defaultModel)
            }
            keyInput = ""
            keyMessage = "Key saved. \(models.count) models found."
        } catch {
            keyMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isValidating = false
    }

    private func reloadModels() {
        let p = appState.activeProvider
        guard let key = KeychainStore.load(for: p), !key.isEmpty else {
            modelsMessage = APIError.noKey.localizedDescription
            return
        }
        loadingModels = true
        modelsMessage = nil
        Task { @MainActor in
            do {
                let models = try await AIClient.fetchAllowedModels(apiKey: key, provider: p)
                appState.availableModels = models
                if !models.contains(appState.defaultModelId) {
                    appState.defaultModelId = models.contains(p.defaultModel)
                        ? p.defaultModel
                        : (models.first ?? p.defaultModel)
                }
                modelsMessage = "\(models.count) models found."
            } catch {
                modelsMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            loadingModels = false
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
