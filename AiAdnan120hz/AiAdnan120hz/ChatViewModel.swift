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
    /// True kalau cancel() dipanggil eksplisit (tombol stop). Bedakan dari
    /// cancel misterius (double-tap / lifecycle) supaya tidak nuduh user.
    private var cancelledByUser = false

    func cancel() {
        cancelledByUser = true
        streamTask?.cancel()
        streamTask = nil
        isSending = false
        streamingText = ""
    }

    /// Error jaringan transient yang layak dicoba ulang sekali.
    private static nonisolated func isTransientNetwork(_ e: URLError) -> Bool {
        switch e.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .dataNotAllowed, .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    /// Kirim pesan user + gambar. `imageDatas` = JPEG siap kirim (foto/video frames).
    func send(conversation: Conversation, text: String,
              imageDatas: [(data: Data, isVideoFrame: Bool)],
              note: String?, context: ModelContext, appState: AppState) {
        // Recover stuck state: isSending true tapi tidak ada task berjalan
        // (mis. task mati sebelum reset). Tanpa ini, semua kirim gagal diam-diam.
        if isSending && streamTask == nil {
            print("[SiriAi] send(): recovering stuck isSending state")
            isSending = false
            streamingText = ""
        }
        guard !isSending else {
            print("[SiriAi] send(): ignored, already sending")
            return
        }
        let provider = appState.activeProvider
        guard let apiKey = KeychainStore.load(for: provider), !apiKey.isEmpty else {
            let msg = APIError.noKey.localizedDescription
            print("[SiriAi] send(): aborted — no API key for \(provider.rawValue)")
            lastError = msg
            return
        }
        // Model id basi/kosong → normalisasi ke model bawaan provider aktif.
        // Pakai resolvedModelId: validasi terhadap daftar server + default.
        // Migrasi: ID lama yang salah (strip) → ID yang benar (titik).
        if conversation.modelId == "free/glm-5-3-flash" {
            conversation.modelId = "free/glm-5.3-flash"
            try? context.save()
        }
        // Migrasi: model NVIDIA lama → default Apinex.
        if conversation.modelId.hasPrefix("z-ai/") {
            conversation.modelId = "free/glm-5.3-flash"
            try? context.save()
        }
        var modelId = conversation.modelId.isEmpty ? appState.resolvedModelId(for: provider) : conversation.modelId
        if !provider.allowsModel(modelId) {
            modelId = provider.defaultModel
        }
        // Validasi tambahan: kalau model conversation tidak ada di daftar server
        // (dan bukan default), pakai hasil resolved.
        if !appState.availableModels.isEmpty,
           !appState.availableModels.contains(modelId),
           modelId != provider.defaultModel {
            modelId = appState.resolvedModelId(for: provider)
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

        // 2. Bangun payload.
        let apiMessages = buildAPIMessages(conversation: conversation, context: context,
                                           currentText: trimmed, currentImages: imageDatas,
                                           memoryEnabled: appState.memoryEnabled,
                                           excludeMessageId: userMsg.id)

        // 3. Placeholder pesan asisten untuk streaming.
        let assistantMsg = ChatMessage(role: "assistant", text: "")
        conversation.messages.append(assistantMsg)
        try? context.save()

        print("[SiriAi] send(): provider=\(provider.rawValue) model=\(modelId) text=\(trimmed.prefix(60)) images=\(imageDatas.count)")

        // Capture immutable copies for the Task (Swift 6 concurrency).
        let taskModelId = modelId
        let taskAssistantMsg = assistantMsg
        let taskApiMessages = apiMessages
        let taskProvider = provider
        let taskApiKey = apiKey
        let taskTrimmed = trimmed
        let taskImageDatas = imageDatas
        let taskConversation = conversation
        let taskNote = note

        streamTask = Task { @MainActor in
            // Satu putaran kirim (dipanggil 2x kalau retry).
            // Jaringan transient (timeout/putus) → coba ulang sekali sebelum fallback model.
            func runTurn(model: String) async throws -> String {
                func attempt() async throws -> String {
                    let ghConnected = !(GitHubStore.load() ?? "").isEmpty
                    if ghConnected {
                        // Mode AGENT: AI bisa panggil tools GitHub beneran.
                        // Kalau model tidak support function calling → fallback streaming biasa.
                        do {
                            return try await self.agentTurn(apiKey: taskApiKey, provider: taskProvider, model: model,
                                                            messages: taskApiMessages)
                        } catch is AIClient.ToolsNotSupported {
                            let (t, _) = try await self.streamingTurn(apiKey: taskApiKey, provider: taskProvider, model: model,
                                                                      messages: taskApiMessages)
                            return t
                        }
                    } else {
                        let (t, _) = try await self.streamingTurn(apiKey: taskApiKey, provider: taskProvider, model: model,
                                                                  messages: taskApiMessages)
                        return t
                    }
                }
                do {
                    return try await attempt()
                } catch let e as APIError {
                    if case .network(let urlErr) = e, Self.isTransientNetwork(urlErr) {
                        print("[SiriAi] jaringan transient (\(urlErr.code.rawValue)); retry sekali")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        try Task.checkCancellation() // user stop → jangan retry
                        return try await attempt()
                    }
                    throw e
                }
            }

            var currentModelId = taskModelId
            do {
                let full: String
                do {
                    full = try await runTurn(model: currentModelId)
                } catch let e as APIError {
                    // Cancel → jangan buang waktu coba model lain.
                    if case .network(let urlErr) = e, urlErr.code == .cancelled {
                        throw e
                    }
                    // KONEKSI DIPERKUAT: coba semua model yang tersedia secara berurutan.
                    // Kalau model utama gagal (404/400/timeout), coba model lain sebelum menyerah.
                    let candidates: [String] = {
                        var list = [currentModelId]
                        // Tambah model fallback provider.
                        for m in taskProvider.modelFallback where !list.contains(m) {
                            list.append(m)
                        }
                        // Tambah dari daftar server kalau ada.
                        for m in appState.availableModels where !list.contains(m) && taskProvider.allowsModel(m) {
                            list.append(m)
                        }
                        return list
                    }()
                    print("[SiriAi] Model \(currentModelId) gagal (\(e)); coba \(candidates.count) kandidat")
                    var lastError = e
                    var succeeded: String? = nil
                    for (idx, candidate) in candidates.enumerated() {
                        if idx == 0 { continue } // sudah dicoba di atas
                        // Backoff: tunggu sebentar sebelum coba model lain.
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                        do {
                            print("[SiriAi] Retry dengan model \(candidate)")
                            let result = try await runTurn(model: candidate)
                            // Sukses: simpan model yang work ke conversation.
                            currentModelId = candidate
                            taskConversation.modelId = candidate
                            try? context.save()
                            succeeded = result
                            break
                        } catch let retryError as APIError {
                            // Cancel → stop, jangan coba model lain.
                            if case .network(let urlErr) = retryError, urlErr.code == .cancelled {
                                throw retryError
                            }
                            print("[SiriAi] Model \(candidate) juga gagal: \(retryError)")
                            lastError = retryError
                            continue
                        }
                    }
                    if let result = succeeded {
                        full = result
                    } else {
                        throw lastError
                    }
                }
                print("[SiriAi] response OK (\(full.count) chars)")
                taskAssistantMsg.text = full
                taskAssistantMsg.errorText = nil
                try? context.save()
                // 4. Ingatan + ringkasan (background task, diam kalau gagal).
                if appState.memoryEnabled {
                    Task { @MainActor in
                        await MemoryService.learnFromExchange(apiKey: taskApiKey, provider: taskProvider, model: currentModelId,
                                                             userText: taskTrimmed, assistantText: full,
                                                             context: context)
                    }
                }
                Task { @MainActor in
                    await MemoryService.maybeSummarize(apiKey: taskApiKey, provider: taskProvider, model: currentModelId,
                                                      conversation: taskConversation, context: context)
                }
            } catch let e as APIError {
                // Cancel paksa (user stop / double-tap) → diam, bukan error.
                if case .network(let urlErr) = e, urlErr.code == .cancelled {
                    print("[SiriAi] request cancelled; silent=\(self.cancelledByUser)")
                    if !self.cancelledByUser {
                        taskAssistantMsg.errorText = "Terputus. Ketuk \"Try again\"."
                        self.lastError = "Terputus. Ketuk \"Try again\"."
                        try? context.save()
                    }
                } else {
                    print("[SiriAi] APIError: \(e.localizedDescription.prefix(200))")
                    taskAssistantMsg.text = ""
                    let desc = Self.visionHintIfNeeded(e.localizedDescription, hadImages: !taskImageDatas.isEmpty)
                    taskAssistantMsg.errorText = desc
                    self.lastError = desc
                    try? context.save()
                }
            } catch is CancellationError {
                // Task di-cancel: user stop → diam. Selain itu → pesan ramah.
                print("[SiriAi] CancellationError; silent=\(self.cancelledByUser)")
                if !self.cancelledByUser {
                    taskAssistantMsg.errorText = "Terputus. Ketuk \"Try again\"."
                    self.lastError = "Terputus. Ketuk \"Try again\"."
                    try? context.save()
                }
            } catch {
                print("[SiriAi] error: \(error.localizedDescription.prefix(200))")
                var desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                desc = Self.visionHintIfNeeded(desc, hadImages: !taskImageDatas.isEmpty)
                taskAssistantMsg.errorText = desc
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
                               messages: [AIClient.APIMessage]) async throws -> (String, Int) {
        var full = ""
        var streamTokens = 0
        // Coba streaming dulu; kalau server menolak, fallback non-streaming.
        do {
            print("[SiriAi] streaming: \(model) @ \(provider.baseURL.host ?? "?")")
            for try await token in AIClient.streamChat(apiKey: apiKey, provider: provider, model: model,
                                                           messages: messages) {
                full += token
                streamTokens += 1
                self.streamingText = full
            }
            // Token streaming dihitung asli; tambah estimasi prompt.
            let promptEst = messages.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
            TokenUsage.record(tokens: streamTokens + promptEst)
        } catch is AIClient.StreamSetupFailed {
            print("[SiriAi] stream setup failed; falling back to non-streaming")
            full = try await AIClient.sendChat(apiKey: apiKey, provider: provider, model: model,
                                                   messages: messages)
            self.streamingText = full
            let promptEst = messages.reduce(0) { $0 + TokenUsage.estimateTokens(for: $1.debugText) }
            TokenUsage.record(tokens: promptEst + TokenUsage.estimateTokens(for: full))
        }
        return (full, streamTokens)
    }

    /// Jalur AGENT: tool loop GitHub (non-streaming).
    /// Selama proses, typing indicator tampil (streamingText kosong + isSending).
    private func agentTurn(apiKey: String, provider: AIProvider, model: String,
                           messages: [AIClient.APIMessage]) async throws -> String {
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
