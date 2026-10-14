import Foundation
import SwiftData

// MARK: - Ingatan AI: 100% lokal (SwiftData). Bukan cloud, bukan server.
// - Fakta jangka panjang: diekstrak otomatis dari obrolan (bisa dimatikan).
// - Ringkasan rolling: konteks lama diringkas agar muat di prompt.

@MainActor
enum MemoryService {
    static let maxFacts = 50

    static func systemPromptExtra(context: ModelContext, memoryEnabled: Bool,
                                  conversation: Conversation) -> String {
        var parts: [String] = []
        if memoryEnabled {
            let facts = (try? context.fetch(FetchDescriptor<MemoryFact>(
                sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            if !facts.isEmpty {
                let lines = facts.map { "- \($0.fact)" }.joined(separator: "\n")
                parts.append("Fakta tentang pengguna (ingatan lokal, bisa salah — jangan diumbar):\n\(lines)")
            }
        }
        if !conversation.summary.isEmpty {
            parts.append("Ringkasan obrolan sebelumnya:\n\(conversation.summary)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Ekstrak fakta tahan lama dari pertukaran terakhir.
    /// Dipanggil sebagai `Task { await ... }` dari konteks @MainActor.
    static func learnFromExchange(apiKey: String, provider: AIProvider, model: String,
                                  userText: String, assistantText: String,
                                  context: ModelContext) async {
        guard userText.count > 20 else { return }
        let prompt = """
        Dari percakapan ini, ekstrak maksimal 3 fakta TENTANG PENGGUNA yang layak diingat jangka panjang \
        (nama, preferensi, pekerjaan, hal penting). Abaikan fakta tentang topik umum. \
        Jawab HANYA sebagai JSON array of string, mis. ["..."]. Kalau tidak ada, jawab [].
        Pengguna: \(userText.prefix(1500))
        Asisten: \(assistantText.prefix(1500))
        """
        let msg = AIClient.APIMessage(role: "user", content: .text(prompt))
        do {
            let raw = try await AIClient.sendChat(apiKey: apiKey, provider: provider, model: model, messages: [msg])
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
    static func maybeSummarize(apiKey: String, provider: AIProvider, model: String,
                               conversation: Conversation, context: ModelContext) async {
        let count = conversation.messages.count
        guard count > 40 else { return }
        let oldest = conversation.messages.sorted { $0.createdAt < $1.createdAt }.prefix(20)
            .map { "[\($0.role)]: \($0.text.prefix(800))" }.joined(separator: "\n")
        let prompt = "Ringkas percakapan berikut jadi 5-8 baris padat (Bahasa Indonesia):\n\(oldest)"
        let msg = AIClient.APIMessage(role: "user", content: .text(prompt))
        do {
            let summary = try await AIClient.sendChat(apiKey: apiKey, provider: provider, model: model, messages: [msg])
            TokenUsage.record(tokens: TokenUsage.estimateTokens(for: prompt) + TokenUsage.estimateTokens(for: summary))
            conversation.summary = summary
            try? context.save()
        } catch { /* diam */ }
    }
}
