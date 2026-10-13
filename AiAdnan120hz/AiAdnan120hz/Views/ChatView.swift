import SwiftUI
import SwiftData

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()

    @State private var inputText = ""
    @State private var showDocPicker = false
    @State private var showWebSource = false
    @State private var alertText: String?
    @State private var storageWarning: String?

    private var sortedMessages: [ChatMessage] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let storageWarning {
                Text(storageWarning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Color.orange.opacity(0.12))
            }

            if !conversation.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(conversation.sources) { src in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                Text(src.fileName).lineLimit(1)
                                Button {
                                    context.delete(src)
                                    try? context.save()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sortedMessages) { msg in
                            MessageRow(message: msg,
                                       isStreaming: viewModel.isSending && msg.id == sortedMessages.last?.id,
                                       streamingText: viewModel.streamingText,
                                       onRetry: { Task { @MainActor in
                                           viewModel.retryLast(conversation: conversation, context: context, appState: appState)
                                       } },
                                       onDelete: {
                                           context.delete(msg)
                                           try? context.save()
                                       })
                            .id(msg.id)
                        }
                    }
                    .padding()
                }
                .background(Color(.systemBackground))
                .onChange(of: sortedMessages.count) { _, _ in
                    if let last = sortedMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    if let last = sortedMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Button { showDocPicker = true } label: {
                        Label("Import Source (txt/md/pdf)", systemImage: "doc.badge.plus")
                    }
                    Button { showWebSource = true } label: {
                        Label("Source Web (URL)", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }

                TextField("Tulis pesan…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button { Task { @MainActor in send() } } label: {
                    Image(systemName: viewModel.isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(viewModel.isSending ? false : inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if appState.availableModels.isEmpty {
                        Text("Belum ada daftar model")
                    } else {
                        ForEach(appState.availableModels, id: \.self) { m in
                            Button {
                                conversation.modelId = m
                                try? context.save()
                            } label: {
                                HStack {
                                    Text(m)
                                    if m == conversation.modelId { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Muat ulang daftar model") { reloadModels() }
                } label: {
                    HStack(spacing: 4) {
                        Text(conversation.modelId.isEmpty ? "Model" : shortModelName)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
            }
        }
        .sheet(isPresented: $showDocPicker) {
            DocumentPicker { importSource(from: $0) }
        }
        .sheet(isPresented: $showWebSource) {
            WebSourceView(conversation: conversation)
        }
        .alert("Info", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        .onAppear { checkStorage() }
        .onDisappear { Task { @MainActor in viewModel.cancel() } }
    }

    private var shortModelName: String {
        let m = conversation.modelId
        return m.count > 22 ? String(m.prefix(22)) + "…" : m
    }

    @MainActor
    private func send() {
        if viewModel.isSending { viewModel.cancel(); return }
        viewModel.send(conversation: conversation, text: inputText,
                       imageDatas: [], note: nil,
                       context: context, appState: appState)
        inputText = ""
    }

    private func reloadModels() {
        guard let key = KeychainStore.load(), !key.isEmpty else {
            alertText = APIError.noKey.localizedDescription
            return
        }
        Task { @MainActor in
            do {
                let models = try await APInexClient.fetchFreeModels(apiKey: key)
                await MainActor.run {
                    appState.availableModels = models
                    if !models.contains(conversation.modelId) {
                        conversation.modelId = models.first ?? ""
                        try? context.save()
                    }
                }
            } catch {
                await MainActor.run {
                    alertText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func importSource(from url: URL) {
        do {
            let text = try SourceExtractor.extractText(from: url)
            let src = SourceAttachment(fileName: url.lastPathComponent, extractedText: text)
            conversation.sources.append(src)
            try? context.save()
        } catch {
            alertText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func checkStorage() {
        Task.detached {
            let ratio = StorageQuota.usageRatio
            if ratio >= StorageQuota.warnThreshold {
                let used = StorageQuota.formatted(StorageQuota.usedBytes())
                await MainActor.run {
                    storageWarning = "Penyimpanan hampir penuh: \(used) / 25 GB. Hapus obrolan lama bila perlu."
                }
            }
        }
    }
}

// MARK: - Baris pesan

struct MessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let streamingText: String
    let onRetry: () -> Void
    let onDelete: () -> Void

    /// Lebar maksimum bubble: 75% lebar layar (maks 520pt untuk iPad).
    private var maxBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.75, 520)
    }

    private let bubblePadding: CGFloat = 12
    private let bubbleRadius: CGFloat = 16

    var body: some View {
        Group {
            if message.role == "user" {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        imageStrip
                        if !message.text.isEmpty {
                            Text(message.text)
                                .padding(bubblePadding)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: bubbleRadius))
                        }
                        if let note = message.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        if let err = message.errorText, !err.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Gagal", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline).foregroundStyle(.red)
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                Button("Coba lagi") { onRetry() }
                                    .font(.subheadline)
                            }
                            .padding(bubblePadding)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: bubbleRadius))
                        } else {
                            let shown = (isStreaming && !streamingText.isEmpty) ? streamingText : message.text
                            if isStreaming && shown.isEmpty {
                                // Indikator mengetik: AI sedang "berpikir", jangan terkesan instan.
                                TypingIndicator()
                                    .padding(bubblePadding)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: bubbleRadius))
                            } else if shown.isEmpty {
                                // Respons kosong tapi tidak error: tampilkan placeholder
                                // agar tidak terlihat seperti layar hitam.
                                Text("Respons kosong dari AI.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(bubblePadding)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: bubbleRadius))
                            } else {
                                Text(shown)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .padding(bubblePadding)
                                    .background(Color.secondary.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: bubbleRadius))
                            }
                        }
                    }
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                    Spacer(minLength: 40)
                }
            }
        }
        .contextMenu {
            Button("Hapus pesan", role: .destructive) { onDelete() }
            if message.role == "assistant", message.errorText != nil {
                Button("Coba lagi") { onRetry() }
            }
        }
    }

    @ViewBuilder
    private var imageStrip: some View {
        if !message.images.isEmpty {
            HStack {
                ForEach(message.images) { att in
                    if let ui = UIImage(data: att.data) {
                        Image(uiImage: ui)
                            .resizable().scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

// MARK: - Indikator "AI sedang mengetik": 3 titik berdenyut.

struct TypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                    .opacity(phase == i ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
