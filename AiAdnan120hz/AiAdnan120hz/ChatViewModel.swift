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
        let provider = appState.activeProvider
        guard let apiKey = KeychainStore.load(for: provider), !apiKey.isEmpty else {
            lastError = APIError.noKey.localizedDescription
            return
        }
        // Model id basi/kosong → normalisasi ke model bawaan provider aktif.
        var modelId = conversation.modelId.isEmpty ? provider.defaultModel : conversation.modelId
        if !provider.allowsModel(modelId) {
            modelId = provider.defaultModel
            conversation.modelId = modelId
        }
        guard !modelId.isEmpty else {
            lastError = "Belum ada model dipilih. Buka Pengaturan → Muat ulang daftar model."
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
                var full: String
                let ghConnected = !(GitHubStore.load() ?? "").isEmpty
                if ghConnected {
                    // Mode AGENT: AI bisa panggil tools GitHub beneran.
                    // Kalau model tidak support function calling → fallback streaming biasa.
                    do {
                        full = try await self.agentTurn(apiKey: apiKey, provider: provider, model: modelId,
                                                        messages: apiMessages,
                                                        assistantMsg: assistantMsg)
                    } catch is AIClient.ToolsNotSupported {
                        let (t, _) = try await self.streamingTurn(apiKey: apiKey, provider: provider, model: modelId,
                                                                  messages: apiMessages,
                                                                  assistantMsg: assistantMsg)
                        full = t
                    }
                } else {
                    let (t, _) = try await self.streamingTurn(apiKey: apiKey, provider: provider, model: modelId,
                                                              messages: apiMessages,
                                                              assistantMsg: assistantMsg)
                    full = t
                }
                assistantMsg.errorText = nil
                try? context.save()
                // 4. Ingatan + ringkasan (background task, diam kalau gagal).
                if appState.memoryEnabled {
                    Task { @MainActor in
                        await MemoryService.learnFromExchange(apiKey: apiKey, provider: provider, model: modelId,
                                                             userText: trimmed, assistantText: full,
                                                             context: context)
                    }
                }
                Task { @MainActor in
                    await MemoryService.maybeSummarize(apiKey: apiKey, provider: provider, model: modelId,
                                                      conversation: conversation, context: context)
                }
            } catch let e as APIError {
                assistantMsg.text = ""
                let desc = Self.visionHintIfNeeded(e.localizedDescription, hadImages: !imageDatas.isEmpty)
                assistantMsg.errorText = desc
                self.lastError = desc
                try? context.save()
            } catch {
                var desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                desc = Self.visionHintIfNeeded(desc, hadImages: !imageDatas.isEmpty)
                assistantMsg.errorText = desc
                self.lastError = desc
                try? context.save()
            }
            self.isSending = false
            self.streamingText = ""
            self.streamTask = nil
        }
    }

    /// Jalur biasa: streaming dulu, fallback non-streaming.
    /// Mengembalikan (teks lengkap, estimasi token).
    private func streamingTurn(apiKey: String, provider: AIProvider, model: String,
                               messages: [AIClient.APIMessage],
                               assistantMsg: ChatMessage) async throws -> (String, Int) {
        var full = ""
        var streamTokens = 0
        // Coba streaming dulu; kalau server menolak, fallback non-streaming.
        do {
            for try await token in AIClient.streamChat(apiKey: apiKey, provider: provider, model: model,
                                                           messages: messages) {
                full += token
                streamTokens += 1
                self.streamingText = full
                assistantMsg.text = full
            }
            // Token streaming dihitung asli; tambah estimasi prompt.
            let promptEst = messages.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
            TokenUsage.record(tokens: streamTokens + promptEst)
        } catch is AIClient.StreamSetupFailed {
            full = try await AIClient.sendChat(apiKey: apiKey, provider: provider, model: model,
                                                   messages: messages)
            assistantMsg.text = full
            self.streamingText = full
            let promptEst = messages.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
            TokenUsage.record(tokens: promptEst + TokenUsage.estimateTokens(for: full))
        }
        return (full, streamTokens)
    }

    /// Jalur AGENT: tool loop GitHub (non-streaming).
    /// Selama proses, typing indicator tampil (streamingText kosong + isSending).
    private func agentTurn(apiKey: String, provider: AIProvider, model: String,
                           messages: [AIClient.APIMessage],
                           assistantMsg: ChatMessage) async throws -> String {
        var msgs = messages
        var lastText: String? = nil
        for _ in 0..<GitHubAgent.maxIterations {
            try Task.checkCancellation()
            let (text, calls) = try await AIClient.sendChatWithTools(
                apiKey: apiKey, provider: provider, model: model, messages: msgs,
                tools: AIClient.githubTools)
            lastText = text
            guard let calls, !calls.isEmpty else {
                let final = text ?? ""
                assistantMsg.text = final
                self.streamingText = final
                let promptEst = msgs.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
                TokenUsage.record(tokens: promptEst + TokenUsage.estimateTokens(for: final))
                return final
            }
            // Rekam pesan asisten + hasil eksekusi tools untuk putaran berikut.
            msgs.append(AIClient.APIMessage(
                role: "assistant",
                content: .text(text ?? ""),
                toolCalls: calls.map {
                    AIClient.APIMessage.ToolCallOut(
                        id: $0.id,
                        function: .init(name: $0.function.name,
                                        arguments: $0.function.arguments))
                }))
            for call in calls {
                let result = await GitHubAgent.execute(name: call.function.name,
                                                       arguments: call.function.arguments)
                msgs.append(AIClient.APIMessage(role: "tool",
                                                    content: .text(result),
                                                    toolCallId: call.id))
            }
        }
        let final = lastText ?? ""
        assistantMsg.text = final
        self.streamingText = final
        return final
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

    /// Kalau request mengandung gambar dan server menolak karena vision,
    /// tambahkan saran model free yang support vision.
    private static func visionHintIfNeeded(_ desc: String, hadImages: Bool) -> String {
        guard hadImages else { return desc }
        let low = desc.lowercased()
        if low.contains("vision") || low.contains("image") || low.contains("multimodal")
            || low.contains("unsupported") || low.contains("tidak didukung") {
            return desc + "\n\nModel ini tampaknya tidak support analisis gambar. Coba free/glm-5.3-flash."
        }
        return desc
    }

    private func buildAPIMessages(conversation: Conversation, context: ModelContext,
                                  currentText: String,
                                  currentImages: [(data: Data, isVideoFrame: Bool)],
                                  memoryEnabled: Bool,
                                  excludeMessageId: UUID) -> [AIClient.APIMessage] {
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

        if let gh = GitHubStore.load(), !gh.isEmpty {
            system += """

            KAMU PUNYA AKSES GITHUB ASLI (bukan simulasi). User sudah menghubungkan GitHub di menu \
            Konektivitas — token tersimpan aman di HP ini, JANGAN pernah minta token di chat.
            Kamu punya tools function-calling:
            - github_list_repos → daftar semua repo user
            - github_list_files(repo, path_prefix opsional) → daftar file dalam repo (repo format "owner/nama")
            - github_read_file(repo, path) → baca isi file teks
            - github_write_file(repo, path, content, message) → BUAT/EDIT file + auto-commit ke GitHub
            - github_delete_file(repo, path, message) → HAPUS file + auto-commit ke GitHub
            Aturan: kalau user bertanya tentang GitHub / repo / kode ("bisa konek github?", "list repo", \
            "bacakan file ..."), WAJIB pakai tools untuk menjawab dengan data nyata — buktikan, jangan \
            bilang tidak bisa. Tool baca (list/read) boleh langsung dipakai.
            Aturan TULIS/HAPUS (wajib dipatuhi): SEBELUM memanggil github_write_file / github_delete_file, \
            tanya dulu ke user di chat — sebutkan file apa yang akan diubah/dihapus dan pesan commit yang \
            akan dipakai, lalu tunggu user bilang ya/setuju (mis. "mau gua commit dengan pesan X?"). JANGAN \
            pernah panggil tool tulis/hapus tanpa persetujuan eksplisit user.
            Kalau tools tidak tersedia di model ini, arahkan user ke Pengaturan → \
            Konektivitas → GitHub (tetap jangan minta token di chat).
            """
        }

        var out: [AIClient.APIMessage] = [
            AIClient.APIMessage(role: "system", content: .text(system))
        ]

        // Riwayat: 20 pesan terakhir (teks saja), tanpa pesan yang sedang dikirim.
        let history = conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .filter { $0.role != "system" && !$0.text.isEmpty }
            .suffix(20)
        for m in history where m.id != excludeMessageId && (m.role == "user" || m.role == "assistant") {
            out.append(AIClient.APIMessage(role: m.role, content: .text(m.text)))
        }

        // Pesan saat ini (dengan gambar kalau ada).
        // Vision: selalu sertakan text part — banyak server menolak payload
        // yang hanya berisi image tanpa teks.
        if currentImages.isEmpty {
            out.append(AIClient.APIMessage(role: "user", content: .text(currentText)))
        } else {
            var parts: [AIClient.ContentPart] = []
            let caption = currentText.isEmpty ? "Tolong analisis dan jelaskan gambar ini." : currentText
            parts.append(.text(caption))
            for img in currentImages {
                parts.append(.image(dataURL: MediaService.dataURL(jpeg: img.data)))
            }
            out.append(AIClient.APIMessage(role: "user", content: .parts(parts)))
        }
        return out
    }
}
