import Foundation
import SwiftData
import SwiftUI

// MARK: - Orkestrasi kirim chat: bangun konteks → streaming → simpan → ingatan.

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var isSending = false
    @Published var streamingText = ""
    @Published var lastError: String?

    private var streamTask: Task<Void, Never>?

    func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        streamingText = ""
    }

    /// Kirim pesan user + gambar. `imageDatas` = JPEG siap kirim (foto/video frames).
    func send(conversation: Conversation, text: String,
              imageDatas: [(data: Data, isVideoFrame: Bool)],
              note: String?, context: ModelContext, appState: AppState) {
        guard !isSending else { return }
        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            lastError = APIError.noKey.localizedDescription
            return
        }
        // Model id basi/kosong (mis. key diganti tapi daftar model belum dimuat)
        // → tolak dengan pesan jelas, jangan kirim request yang pasti gagal.
        let modelId = conversation.modelId.isEmpty ? appState.defaultModelId : conversation.modelId
        guard !modelId.isEmpty else {
            lastError = "Belum ada model dipilih. Buka Pengaturan → Muat ulang daftar model."
            return
        }
        // Akun free tidak boleh memakai model paid.
        if appState.accountTier == .free && !APInexClient.isFreeModel(modelId) {
            lastError = "Model ini khusus akun Paid. Pilih model free (awalan \"free/\") di Pengaturan."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageDatas.isEmpty else { return }

        lastError = nil
        isSending = true
        streamingText = ""

        // 1. Simpan pesan user.
        let userMsg = ChatMessage(role: "user", text: trimmed, note: note)
        for img in imageDatas {
            userMsg.images.append(ImageAttachment(data: img.data, isVideoFrame: img.isVideoFrame))
        }
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()
        if conversation.title == "Obrolan baru" {
            conversation.title = String(trimmed.prefix(40))
        }
        try? context.save()

        // 2. Bangun payload.
        let apiMessages = buildAPIMessages(conversation: conversation, context: context,
                                           currentText: trimmed, currentImages: imageDatas,
                                           memoryEnabled: appState.memoryEnabled,
                                           excludeMessageId: userMsg.id)

        // 3. Placeholder pesan asisten untuk streaming.
        let assistantMsg = ChatMessage(role: "assistant", text: "")
        conversation.messages.append(assistantMsg)
        try? context.save()

        streamTask = Task { @MainActor in
            do {
                var full = ""
                var streamTokens = 0
                // Coba streaming dulu; kalau server menolak, fallback non-streaming.
                do {
                    for try await token in APInexClient.streamChat(apiKey: apiKey, model: modelId,
                                                                  messages: apiMessages) {
                        full += token
                        streamTokens += 1
                        self.streamingText = full
                        assistantMsg.text = full
                    }
                    // Token streaming dihitung asli; tambah estimasi prompt.
                    let promptEst = apiMessages.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
                    TokenUsage.record(tokens: streamTokens + promptEst)
                } catch is APInexClient.StreamSetupFailed {
                    full = try await APInexClient.sendChat(apiKey: apiKey, model: modelId,
                                                           messages: apiMessages)
                    assistantMsg.text = full
                    self.streamingText = full
                    let promptEst = apiMessages.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
                    TokenUsage.record(tokens: promptEst + TokenUsage.estimateTokens(for: full))
                }
                assistantMsg.errorText = nil
                try? context.save()
                // 4. Ingatan + ringkasan (background task, diam kalau gagal).
                if appState.memoryEnabled {
                    Task { @MainActor in
                        await MemoryService.learnFromExchange(apiKey: apiKey, model: modelId,
                                                             userText: trimmed, assistantText: full,
                                                             context: context)
                    }
                }
                Task { @MainActor in
                    await MemoryService.maybeSummarize(apiKey: apiKey, model: modelId,
                                                      conversation: conversation, context: context)
                }
            } catch let e as APIError {
                assistantMsg.text = ""
                assistantMsg.errorText = e.localizedDescription
                self.lastError = e.localizedDescription
                try? context.save()
            } catch {
                let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                assistantMsg.errorText = desc
                self.lastError = desc
                try? context.save()
            }
            self.isSending = false
            self.streamingText = ""
            self.streamTask = nil
        }
    }

    /// Kirim ulang: hapus pesan asisten terakhir lalu kirim ulang pesan user sebelumnya.
    func retryLast(conversation: Conversation, context: ModelContext, appState: AppState) {
        let sorted = conversation.messages.sorted { $0.createdAt < $1.createdAt }
        guard let lastAssistant = sorted.last(where: { $0.role == "assistant" }),
              let idx = sorted.firstIndex(where: { $0.id == lastAssistant.id }),
              idx > 0 else { return }
        let prevUser = sorted[idx - 1]
        guard prevUser.role == "user" else { return }
        context.delete(lastAssistant)
        try? context.save()
        let imgs = prevUser.images.map { ($0.data, $0.isVideoFrame) }
        send(conversation: conversation, text: prevUser.text, imageDatas: imgs,
             note: prevUser.note, context: context, appState: appState)
    }

    // MARK: - Bangun konteks API

    private func buildAPIMessages(conversation: Conversation, context: ModelContext,
                                  currentText: String,
                                  currentImages: [(data: Data, isVideoFrame: Bool)],
                                  memoryEnabled: Bool,
                                  excludeMessageId: UUID) -> [APInexClient.APIMessage] {
        var system = """
        Kamu adalah "Siri Ai", teman ngobrol yang santai dan natural — \
        BUKAN robot customer service. Gaya bahasa: santai kayak ngobrol sama teman, \
        tidak kaku, tidak formal/baku, jangan pakai banyak emoji (maksimal 1 sesekali, \
        atau tidak sama sekali). Ikuti bahasa pengguna: kalau dia pakai Bahasa Indonesia \
        santai, jawab dengan Bahasa Indonesia santai juga; kalau dia pakai bahasa lain, \
        ikuti bahasa itu dengan gaya yang sama santainya. Jawaban ringkas tapi lengkap, \
        boleh pakai markdown sederhana kalau membantu. Jawab langsung ke intinya tanpa \
        ceramah; hanya tolak permintaan yang benar-benar berbahaya atau ilegal, dan kalau \
        menolak, jelaskan singkat dalam satu kalimat santai.
        """

        let memExtra = MemoryService.systemPromptExtra(context: context,
                                                       memoryEnabled: memoryEnabled,
                                                       conversation: conversation)
        if !memExtra.isEmpty { system += "\n\n\(memExtra)" }

        if !conversation.sources.isEmpty {
            let src = conversation.sources.map {
                "=== Sumber: \($0.fileName) ===\n\($0.extractedText.prefix(12000))"
            }.joined(separator: "\n\n")
            system += "\n\nPengguna melampirkan sumber berikut. Pakai sebagai referensi utama saat relevan:\n\(src)"
        }

        var out: [APInexClient.APIMessage] = [
            APInexClient.APIMessage(role: "system", content: .text(system))
        ]

        // Riwayat: 20 pesan terakhir (teks saja), tanpa pesan yang sedang dikirim.
        let history = conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .filter { $0.role != "system" && !$0.text.isEmpty }
            .suffix(20)
        for m in history where m.id != excludeMessageId && (m.role == "user" || m.role == "assistant") {
            out.append(APInexClient.APIMessage(role: m.role, content: .text(m.text)))
        }

        // Pesan saat ini (dengan gambar kalau ada).
        if currentImages.isEmpty {
            out.append(APInexClient.APIMessage(role: "user", content: .text(currentText)))
        } else {
            var parts: [APInexClient.ContentPart] = []
            if !currentText.isEmpty { parts.append(.text(currentText)) }
            for img in currentImages {
                parts.append(.image(dataURL: MediaService.dataURL(jpeg: img.data)))
            }
            out.append(APInexClient.APIMessage(role: "user", content: .parts(parts)))
        }
        return out
    }
}
