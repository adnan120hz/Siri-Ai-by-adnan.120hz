import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers

struct PendingMedia: Identifiable {
    let id = UUID()
    let data: Data
    let isVideoFrame: Bool
}

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()

    @State private var inputText = ""
    @State private var pendingMedia: [PendingMedia] = []
    @State private var showMediaPicker = false
    @State private var showDocPicker = false
    @State private var showVoice = false
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
                .onChange(of: sortedMessages.count) { _, _ in
                    if let last = sortedMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    if let last = sortedMessages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            if !pendingMedia.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(pendingMedia) { pm in
                            ZStack(alignment: .topTrailing) {
                                if let ui = UIImage(data: pm.data) {
                                    Image(uiImage: ui)
                                        .resizable().scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                Button {
                                    pendingMedia.removeAll { $0.id == pm.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .background(Circle().fill(.white))
                                }
                                .offset(x: 6, y: -6)
                            }
                            .padding(.trailing, 6)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
            }

            HStack(spacing: 8) {
                Menu {
                    Button { showMediaPicker = true } label: {
                        Label("Foto / Video", systemImage: "photo")
                    }
                    Button { showDocPicker = true } label: {
                        Label("Import Source (txt/md/pdf)", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }

                TextField("Tulis pesan…", text: $inputText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)

                Button { showVoice = true } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.title2)
                }

                Button { Task { @MainActor in send() } } label: {
                    Image(systemName: viewModel.isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(viewModel.isSending ? false : (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingMedia.isEmpty))
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
        .sheet(isPresented: $showMediaPicker) {
            MediaPicker { handlePickerResults($0) }
        }
        .sheet(isPresented: $showDocPicker) {
            DocumentPicker { importSource(from: $0) }
        }
        .sheet(isPresented: $showVoice) {
            VoiceModeView(conversation: conversation)
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
        let imgs = pendingMedia.map { ($0.data, $0.isVideoFrame) }
        let frameCount = pendingMedia.filter(\.isVideoFrame).count
        let note: String? = frameCount > 0
            ? "Video dikirim sebagai \(frameCount) frame gambar."
            : nil
        viewModel.send(conversation: conversation, text: inputText,
                       imageDatas: imgs, note: note,
                       context: context, appState: appState)
        inputText = ""
        pendingMedia = []
    }

    private func reloadModels() {
        guard let key = KeychainStore.load(), !key.isEmpty else {
            alertText = APIError.noKey.localizedDescription
            return
        }
        Task {
            do {
                let models = try await APInexClient.fetchModels(apiKey: key)
                await MainActor.run {
                    appState.availableModels = models
                    if conversation.modelId.isEmpty, let first = models.first {
                        conversation.modelId = first
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

    private func handlePickerResults(_ results: [PHPickerResult]) {
        for result in results {
            let provider = result.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    guard let url else { return }
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + ".mov")
                    try? FileManager.default.copyItem(at: url, to: tmp)
                    Task {
                        let frames = await MediaService.extractFrames(from: tmp)
                        await MainActor.run {
                            for f in frames {
                                pendingMedia.append(PendingMedia(data: f, isVideoFrame: true))
                            }
                            if frames.isEmpty {
                                alertText = "Gagal mengekstrak frame dari video."
                            }
                        }
                        try? FileManager.default.removeItem(at: tmp)
                    }
                }
            } else {
                provider.loadObject(ofClass: UIImage.self) { obj, _ in
                    guard let img = obj as? UIImage,
                          let raw = img.jpegData(compressionQuality: 0.9),
                          let scaled = MediaService.downscaleJPEG(raw) else { return }
                    Task { @MainActor in
                        pendingMedia.append(PendingMedia(data: scaled, isVideoFrame: false))
                    }
                }
            }
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

    var body: some View {
        Group {
            if message.role == "user" {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        imageStrip
                        Text(message.text)
                            .padding(10)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        if let note = message.note {
                            Text(note).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
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
                        .padding(10)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        let shown = (isStreaming && !streamingText.isEmpty) ? streamingText : message.text
                        Text(shown.isEmpty && isStreaming ? "…" : shown)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 40)
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
