import Foundation
import SwiftData
import SwiftUI

// MARK: - Orkestrasi kirim chat: bangun konteks → Gemini → simpan → ingatan.
// Transport: GeminiClient (key TANAM via Secrets, tanpa input manual).

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var isSending = false
    @Published var streamingText = ""
    @Published var lastError: String?

    private var sendTask: Task<Void, Never>?
    /// True kalau cancel() dipanggil eksplisit (tombol stop). Bedakan dari
    /// cancel misterius (double-tap / lifecycle) supaya tidak nuduh user.
    private var cancelledByUser = false

    func cancel() {
        cancelledByUser = true
        sendTask?.cancel()
        sendTask = nil
        isSending = false
        streamingText = ""
    }

    /// True kalau error ini adalah pembatalan request (user stop / task cancel).
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case GeminiError.network(let e) = error,
           let urlErr = e as? URLError, urlErr.code == .cancelled {
            return true
        }
        return false
    }

    /// Kirim pesan user + gambar. `imageDatas` = JPEG siap kirim (foto/video frames).
    func send(conversation: Conversation, text: String,
              imageDatas: [(data: Data, isVideoFrame: Bool)],
              note: String?, context: ModelContext, appState: AppState) {
        // Recover stuck state: isSending true tapi tidak ada task berjalan
        // (mis. task mati sebelum reset). Tanpa ini, semua kirim gagal diam-diam.
        if isSending && sendTask == nil {
            print("[SiriAi] send(): recovering stuck isSending state")
            isSending = false
            streamingText = ""
        }
        guard !isSending else {
            print("[SiriAi] send(): ignored, already sending")
            return
        }
        // Key TANAM via Secrets (CI). Kalau kosong = CI misconfig; jangan
        // pernah log nilainya. Tidak ada lagi input key manual.
        guard !Secrets.geminiFreeKey.isEmpty else {
            print("[SiriAi] send(): aborted — embedded key kosong")
            lastError = GeminiError.unauthorized.localizedDescription
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageDatas.isEmpty else { return }

        lastError = nil
        isSending = true
        streamingText = ""
        cancelledByUser = false

        // 1. Simpan pesan user.
        let userMsg = ChatMessage(role: "user", text: trimmed, note: note)
        for img in imageDatas {
            userMsg.images.append(ImageAttachment(data: img.data, isVideoFrame: img.isVideoFrame))
        }
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()
        if conversation.title == "Obrolan baru" {
            if !trimmed.isEmpty {
                conversation.title = String(trimmed.prefix(40))
            } else if !imageDatas.isEmpty {
                conversation.title = "New Photo"
            }
        }
        try? context.save()

        // 2. Bangun prompt: system instruction + riwayat + pesan saat ini.
        let (system, history) = buildPrompt(conversation: conversation, context: context,
                                            memoryEnabled: appState.memoryEnabled,
                                            excludeMessageId: userMsg.id)

        // 3. Placeholder pesan asisten.
        let assistantMsg = ChatMessage(role: "assistant", text: "")
        conversation.messages.append(assistantMsg)
        try? context.save()

        print("[SiriAi] send(): model=\(GeminiClient.primaryModel) text=\(trimmed.prefix(60)) images=\(imageDatas.count)")

        // Capture immutable copies for the Task (Swift 6 concurrency).
        let taskAssistantMsg = assistantMsg
        let taskSystem = system
        let taskHistory = history
        let taskTrimmed = trimmed
        let taskImageDatas = imageDatas
        let taskConversation = conversation
        let taskMemoryEnabled = appState.memoryEnabled

        sendTask = Task { @MainActor in
            do {
                let full: String
                if taskImageDatas.isEmpty {
                    full = try await GeminiClient.sendText(
                        taskTrimmed, history: taskHistory, systemInstruction: taskSystem)
                } else {
                    let imgs = taskImageDatas.map { (data: $0.data, mimeType: "image/jpeg") }
                    full = try await GeminiClient.sendWithImages(
                        taskTrimmed, images: imgs, history: taskHistory, systemInstruction: taskSystem)
                }
                print("[SiriAi] response OK (\(full.count) chars)")
                // Estimasi token kasar untuk pelacak kuota lokal.
                let promptEst = taskHistory.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.text) }
                    + TokenUsage.estimateTokens(for: taskSystem)
                    + TokenUsage.estimateTokens(for: taskTrimmed)
                TokenUsage.record(tokens: promptEst + TokenUsage.estimateTokens(for: full))
                // Strip markdown bold markers (**) — tampil sebagai teks polos.
                let clean = full.replacingOccurrences(of: "**", with: "")
                taskAssistantMsg.text = clean
                taskAssistantMsg.errorText = nil
                self.streamingText = clean
                try? context.save()
                // 4. Ingatan + ringkasan + judul (background task, diam kalau gagal).
                if taskMemoryEnabled {
                    Task { @MainActor in
                        await MemoryService.learnFromExchange(userText: taskTrimmed,
                                                             assistantText: full,
                                                             context: context)
                    }
                }
                Task { @MainActor in
                    await MemoryService.maybeSummarize(conversation: taskConversation,
                                                      context: context)
                }
                Task { @MainActor in
                    await MemoryService.generateTitle(userText: taskTrimmed,
                                                      assistantText: full,
                                                      conversation: taskConversation,
                                                      context: context)
                }
            } catch {
                // Cancel paksa (user stop / double-tap) → diam, bukan error.
                if Self.isCancellation(error) {
                    print("[SiriAi] request cancelled; silent=\(self.cancelledByUser)")
                    if !self.cancelledByUser {
                        taskAssistantMsg.errorText = "Terputus. Ketuk \"Try again\"."
                        self.lastError = "Terputus. Ketuk \"Try again\"."
                        try? context.save()
                    }
                } else {
                    let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    print("[SiriAi] error: \(desc.prefix(200))")
                    taskAssistantMsg.text = ""
                    taskAssistantMsg.errorText = desc
                    self.lastError = desc
                    try? context.save()
                }
            }
            self.isSending = false
            self.streamingText = ""
            self.sendTask = nil
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

    // MARK: - Bangun konteks

    /// Mengembalikan (systemInstruction, history[(role, text)]).
    /// Gaya prompt Siri dipertahankan: singkat, dingin, cool, maks 2-3 kalimat,
    /// tanpa emoji, tanpa markdown, ** di-strip.
    private func buildPrompt(conversation: Conversation, context: ModelContext,
                             memoryEnabled: Bool,
                             excludeMessageId: UUID) -> (String, [(role: String, text: String)]) {
        var system = """
        Kamu adalah "Siri Ai". Gaya: singkat, dingin, cool kayak Siri asli. \
        Jawab seperlunya saja — maksimal 2-3 kalimat untuk hal sederhana. \
        Jangan bertele-tele, jangan ceramah, jangan pakai emoji. \
        Jangan pakai format markdown (tanpa **, tanpa #, tanpa list). \
        Teks polos saja. Ikuti bahasa pengguna.
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

        if let gh = GitHubStore.load(), !gh.isEmpty {
            system += """

            KAMU PUNYA AKSES GITHUB ASLI (bukan simulasi). User sudah menghubungkan GitHub di menu \
            Konektivitas — token tersimpan aman di HP ini, JANGAN pernah minta token di chat.
            Catatan jujur: di build ini AI tidak punya function-calling tools — kamu menjawab \
            dari teks yang user berikan di chat. Jangan mengklaim bisa memanggil tools \
            (list/read/write file GitHub). Kalau user bertanya soal repo/kode, jawab dari \
            konteks yang ada, atau arahkan user ke menu Konektivitas → GitHub di app.
            """
        }

        // Riwayat: 20 pesan terakhir (teks saja), tanpa pesan yang sedang dikirim.
        // Role "assistant" dipetakan ke "model" oleh GeminiClient.
        var history: [(role: String, text: String)] = []
        let past = conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .filter { $0.role != "system" && !$0.text.isEmpty }
            .suffix(20)
        for m in past where m.id != excludeMessageId && (m.role == "user" || m.role == "assistant") {
            history.append((role: m.role, text: m.text))
        }
        return (system, history)
    }
}
