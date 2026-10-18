import Foundation
import SwiftData

// MARK: - Ingatan AI: 100% lokal (SwiftData). Bukan cloud, bukan server.
// - Fakta jangka panjang: diekstrak otomatis dari obrolan (bisa dimatikan).
// - Ringkasan rolling: konteks lama diringkas agar muat di prompt.

@MainActor
enum MemoryService {
    static let maxFacts = 50

    /// "Other API Key": sama seperti ChatViewModel — true hanya kalau premium
    /// DAN toggle ON; selebihnya key 1 (free).
    private static var useEffectivePremiumKey: Bool {
        PremiumState.shared.isPremium && PremiumFeatures.shared.usePremiumKey
    }

    static func systemPromptExtra(context: ModelContext, memoryEnabled: Bool,
                                  conversation: Conversation) -> String {
        var parts: [String] = []
        if memoryEnabled {
            let facts = (try? context.fetch(FetchDescriptor<MemoryFact>(
                sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            if !facts.isEmpty {
                let lines = facts.map { "- \($0.fact)" }.joined(separator: "\n")
                parts.append("Facts about the user (local memory, may be wrong — do not reveal):\n\(lines)")
            }
        }
        if !conversation.summary.isEmpty {
            parts.append("Previous chat summary:\n\(conversation.summary)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Ekstrak fakta tahan lama dari pertukaran terakhir.
    /// Dipanggil sebagai `Task { await ... }` dari konteks @MainActor.
    /// Key TANAM (Secrets) — tidak ada lagi apiKey/provider dari user.
    @MainActor
    static func learnFromExchange(userText: String, assistantText: String,
                                  context: ModelContext) async {
        guard userText.count > 20 else { return }
        let prompt = """
        From this conversation, extract at most 3 facts ABOUT THE USER worth remembering long-term \
        (name, preferences, job, important things). Ignore facts about general topics. \
        Answer ONLY as a JSON array of strings, e.g. ["..."]. If none, answer [].
        User: \(userText.prefix(1500))
        Assistant: \(assistantText.prefix(1500))
        """
        do {
            let raw = try await GroqClient.sendText(prompt, usePremiumKey: useEffectivePremiumKey)
            TokenUsage.record(tokens: TokenUsage.estimateTokens(for: prompt) + TokenUsage.estimateTokens(for: raw))
            guard let data = raw.data(using: .utf8),
                  let facts = try? JSONDecoder().decode([String].self, from: data),
                  !facts.isEmpty else { return }
            let existing = (try? context.fetch(FetchDescriptor<MemoryFact>())) ?? []
            for f in facts.prefix(3) {
                let trimmed = f.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && existing.count < maxFacts
                    && !existing.contains(where: { $0.fact == trimmed }) {
                    context.insert(MemoryFact(fact: trimmed))
                }
            }
            try? context.save()
        } catch { /* ingatan gagal = diam, bukan error ke user */ }
    }

    /// Ringkas 20 pesan tertua jadi summary kalau obrolan sudah panjang.
    @MainActor
    static func maybeSummarize(conversation: Conversation, context: ModelContext) async {
        let count = conversation.messages.count
        guard count > 40 else { return }
        let oldest = conversation.messages.sorted { $0.createdAt < $1.createdAt }.prefix(20)
            .map { "[\($0.role)]: \($0.text.prefix(800))" }.joined(separator: "\n")
        let prompt = "Summarize the following conversation into 5-8 dense lines (English):\n\(oldest)"
        do {
            let summary = try await GroqClient.sendText(prompt, usePremiumKey: useEffectivePremiumKey)
            TokenUsage.record(tokens: TokenUsage.estimateTokens(for: prompt) + TokenUsage.estimateTokens(for: summary))
            conversation.summary = summary
            try? context.save()
        } catch { /* diam */ }
    }

    /// Generate judul singkat dari topik percakapan via AI (maks 5 kata).
    /// Dipanggil sekali setelah pesan pertama terkirim.
    static func generateTitle(userText: String, assistantText: String,
                              conversation: Conversation, context: ModelContext) async {
        // Hanya generate kalau judul masih default.
        guard conversation.title == "New chat" else { return }
        let prompt = """
        Create a short title (max 5 words, English, no quotes) for this conversation:
        User: \(userText.prefix(200))
        AI: \(assistantText.prefix(200))
        Title:
        """
        do {
            let title = try await GroqClient.sendText(prompt, usePremiumKey: useEffectivePremiumKey)
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "**", with: "")
            if !clean.isEmpty && clean.count <= 60 {
                conversation.title = clean
                try? context.save()
            }
        } catch { /* diam — judul tetap default */ }
    }
}
