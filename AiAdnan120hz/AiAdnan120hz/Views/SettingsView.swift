import SwiftUI
import SwiftData


// MARK: - Settings. Native Form.
// Key Gemini TANAM via Secrets (CI) — tidak ada input key manual.
// Voice, appearance, dynamic storage cap (25GB free / 50GB premium), local memory.

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MemoryFact.createdAt, order: .reverse) private var facts: [MemoryFact]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var storageText = "Calculating…"
    @State private var storageRatio: Double = 0

    var body: some View {
        NavigationStack {
            Form {
                // Key tertanam; kalau kosong = CI misconfig.
                if !appState.hasAPIKey {
                    Section {
                        Label("AI key is not embedded. Rebuild from CI with the correct GitHub Secrets.",
                              systemImage: "key.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
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
                    Text("\(storageText) / \(StorageQuota.formatted(StorageQuota.capBytes))")
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
                    Text("Siri Ai — AI chat powered by Groq. No account, no login.")
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

    private func refreshStorage() {
        Task.detached {
            let used = StorageQuota.usedBytes()
            await MainActor.run {
                let ratio = Double(used) / Double(StorageQuota.capBytes)
                storageText = StorageQuota.formatted(used)
                storageRatio = min(1.0, ratio)
            }
        }
    }
}
