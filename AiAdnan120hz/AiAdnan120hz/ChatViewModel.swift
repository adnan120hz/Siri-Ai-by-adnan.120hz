import Foundation
import SwiftData
import SwiftUI
import Combine

// MARK: - Chat orchestration: build context → Groq → save → memory.
// Transport: GroqClient (embedded key via Secrets, no manual input).

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var isSending = false
    @Published var streamingText = ""
    @Published var lastError: String?
    /// Free-limit block: ditampilkan sebagai banner di ChatView (nil = tidak ada blokir).
    @Published var limitNotice: LimitNotice?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Kalau user redeem di tengah sesi: bersihkan banner limit yang sudah basi.
        PremiumState.shared.$isPremium
            .receive(on: DispatchQueue.main)
            .sink { [weak self] premium in
                if premium { self?.limitNotice = nil }
            }
            .store(in: &cancellables)
    }

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
        if case GroqError.network(let e) = error,
           let urlErr = e as? URLError, urlErr.code == .cancelled {
            return true
        }
        return false
    }

    // MARK: - Kirim pesan

    /// "Other API Key": true HANYA kalau premium DAN toggle ON.
    /// Segala kondisi lain (bukan premium, atau toggle mati) → selalu key 1 (free).
    private static var useEffectivePremiumKey: Bool {
        PremiumState.shared.isPremium && PremiumFeatures.shared.usePremiumKey
    }

    /// Kirim pesan user + gambar. `imageDatas` = JPEG siap kirim (foto/video frames).
    /// `fileImages` = lampiran gambar (kini selalu kosong; dokumen premium hanya pdf/zip),
    /// sudah membawa mimeType aslinya — dikirim via `sendWithImages`.
    func send(conversation: Conversation, text: String,
              imageDatas: [(data: Data, isVideoFrame: Bool)],
              fileImages: [(data: Data, mimeType: String)] = [],
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
        guard !Secrets.groqFreeKey.isEmpty else {
            print("[SiriAi] send(): aborted — embedded key kosong")
            lastError = GroqError.unauthorized.localizedDescription
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !imageDatas.isEmpty || !fileImages.isEmpty else { return }

        limitNotice = nil
        // FREE LIMITS (premium melewati). Urutan: per-chat dulu, baru per-hari.
        if !PremiumState.shared.isPremium {
            guard FreeLimits.canSendInChat(conversation: conversation) else {
                print("[SiriAi] send(): blocked — per-chat free limit (20) tercapai")
                limitNotice = LimitNotice(kind: .perChat)
                return
            }
            guard FreeLimits.canSendToday() else {
                print("[SiriAi] send(): blocked — daily free limit (40) tercapai")
                limitNotice = LimitNotice(kind: .perDay)
                return
            }
        }

        // STORAGE: tolak sebelum menulis kalau proyeksi melebihi cap dinamis
        // (25 GB free / 50 GB premium). Teks = estimasi lampiran + teks pesan;
        // ini best-effort karena SwiftData save-nya implisit (lihat catatan di
        // bawah), bukan enforcement total.
        let incomingBytes = Int64(imageDatas.reduce(0) { $0 + $1.data.count })
            + Int64(fileImages.reduce(0) { $0 + $1.data.count })
            + Int64(trimmed.utf8.count)
        guard StorageQuota.canAccommodate(incomingBytes) else {
            print("[SiriAi] send(): blocked — storage quota tercapai")
            lastError = StorageQuota.fullMessage
            return
        }

        lastError = nil
        isSending = true
        streamingText = ""
        cancelledByUser = false

        // 1. Simpan pesan user.
        let userMsg = ChatMessage(role: "user", text: trimmed, note: note)
        for img in imageDatas {
            userMsg.images.append(ImageAttachment(data: img.data, isVideoFrame: img.isVideoFrame))
        }
        for f in fileImages {
            userMsg.images.append(ImageAttachment(data: f.data, isVideoFrame: false))
        }
        conversation.messages.append(userMsg)
        conversation.updatedAt = Date()
        if conversation.title == "New chat" {
            if !trimmed.isEmpty {
                conversation.title = String(trimmed.prefix(40))
            } else if !imageDatas.isEmpty || !fileImages.isEmpty {
                conversation.title = "New Photo"
            }
        }
        try? context.save()
        // Catatan jujur storage: SwiftData menyimpan implisit via context.save();
        // enforcement kuota di sini best-effort (cek proyeksi sebelum append di
        // atas), bukan enforcement total di level database.
        // Definisi "1 pesan" = 1 pesan user yang berhasil dikirim (free tier saja).
        if !PremiumState.shared.isPremium { FreeLimits.recordSent() }

        // 2. Bangun prompt: system instruction + riwayat + pesan saat ini.
        let (system, history) = buildPrompt(conversation: conversation, context: context,
                                            memoryEnabled: appState.memoryEnabled,
                                            excludeMessageId: userMsg.id)

        // 3. Placeholder pesan asisten.
        let assistantMsg = ChatMessage(role: "assistant", text: "")
        conversation.messages.append(assistantMsg)
        try? context.save()

        print("[SiriAi] send(): model=\(GroqClient.primaryModel) text=\(trimmed.prefix(60)) images=\(imageDatas.count) fileImages=\(fileImages.count) premiumKey=\(Self.useEffectivePremiumKey)")

        // Capture immutable copies for the Task (Swift 6 concurrency).
        let taskAssistantMsg = assistantMsg
        let taskSystem = system
        let taskHistory = history
        let taskTrimmed = trimmed
        let taskImageDatas = imageDatas
        let taskFileImages = fileImages
        let taskConversation = conversation
        let taskMemoryEnabled = appState.memoryEnabled
        let taskUsePremiumKey = Self.useEffectivePremiumKey

        sendTask = Task { @MainActor in
            do {
                let full: String
                let allImages = taskImageDatas.map { (data: $0.data, mimeType: "image/jpeg") }
                    + taskFileImages
                if allImages.isEmpty {
                    full = try await GroqClient.sendText(
                        taskTrimmed, history: taskHistory, systemInstruction: taskSystem,
                        usePremiumKey: taskUsePremiumKey)
                } else {
                    full = try await GroqClient.sendWithImages(
                        taskTrimmed, images: allImages, history: taskHistory,
                        systemInstruction: taskSystem, usePremiumKey: taskUsePremiumKey)
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
                        taskAssistantMsg.errorText = "Disconnected. Tap \"Try again\"."
                        self.lastError = "Disconnected. Tap \"Try again\"."
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
        You are "Siri Ai", created by Adnan.120hz. If asked who made or created you, \
        say Adnan.120hz. NEVER claim to be made by OpenAI, Google, Meta, or any other company. \
        Style: short, cold, cool like the real Siri. \
        Answer only as much as needed — at most 2-3 sentences for simple things. \
        No rambling, no lectures, no emoji. \
        No markdown formatting (no **, no #, no lists). \
        Plain text only. Follow the user's language.
        """

        let memExtra = MemoryService.systemPromptExtra(context: context,
                                                       memoryEnabled: memoryEnabled,
                                                       conversation: conversation)
        if !memExtra.isEmpty { system += "\n\n\(memExtra)" }

        if !conversation.sources.isEmpty {
            let src = conversation.sources.map {
                "=== Source: \($0.fileName) ===\n\($0.extractedText.prefix(12000))"
            }.joined(separator: "\n\n")
            system += "\n\nThe user attached the following sources. Use them as the primary reference when relevant:\n\(src)"
        }

        if let gh = GitHubStore.load(), !gh.isEmpty {
            system += """

            YOU HAVE REAL GITHUB ACCESS (not a simulation). The user connected GitHub in the \
            Connectivity menu — the token is stored safely on this phone, NEVER ask for a token in chat.
            Honest note: in this build the AI has no function-calling tools — you answer \
            from the text the user provides in chat. Do not claim you can call tools \
            (list/read/write GitHub files). If the user asks about repos/code, answer from \
            the available context, or point them to Connectivity → GitHub in the app.
            """
        }

        // PROMPT MODE (premium saja): lapisi gaya bicara pilihan user TANPA
        // mengganti instruksi dasar Siri di atas — digabung dengan "\n\n",
        // bukan di-replace. Free tier selalu memakai instruksi dasar saja.
        if PremiumState.shared.isPremium {
            let modeExtra = PromptMode.selected.systemInstruction()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !modeExtra.isEmpty {
                system += "\n\n\(modeExtra)"
            }
        }

        // History: last 20 messages (text only), excluding the one being sent.
        // Roles "user"/"assistant" pass through unchanged (OpenAI format).
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

// MARK: - Free-limit block: jenis blokir pengiriman untuk free tier.

/// Alasan pemblokiran free-limit. ChatView menampilkannya sebagai banner
/// dengan tombol aksi (Buat chat baru / Get subscriptions).
struct LimitNotice: Identifiable {
    enum Kind { case perChat, perDay }
    let id = UUID()
    let kind: Kind
}
