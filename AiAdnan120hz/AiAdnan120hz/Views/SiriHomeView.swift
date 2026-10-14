import SwiftUI
import SwiftData

// MARK: - Layar utama Siri Ai: seperti foto referensi.
// Background putih (light) / hitam (dark), X kiri atas, orb di tengah,
// bottom bar: + | "Ask Siri" | mic. Menu + : Camera, Photos, Files.

struct SiriHomeView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var voice = VoiceService()
    @Binding var showHistory: Bool

    @State private var inputText = ""
    @State private var pendingImages: [Data] = []
    @State private var showPlusMenu = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var alertText: String?
    @FocusState private var fieldFocused: Bool
    @State private var wasSending = false

    private var sortedMessages: [ChatMessage] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    /// Ada yang bisa dikirim: teks atau gambar.
    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // X kiri atas → layar history.
                HStack {
                    Button { showHistory = true } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color(.systemGray6)))
                    }
                    .accessibilityLabel("Riwayat")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Area tengah: orb (kosong) / daftar pesan.
                ZStack {
                    if sortedMessages.isEmpty {
                        // Empty state: orb di tengah, seperti foto.
                        SiriOrbView(animate: viewModel.isSending || voice.isRecording)
                            .opacity(0.5)
                    } else {
                        // Ada pesan: orb jadi watermark faint di belakang.
                        SiriOrbView(animate: viewModel.isSending || voice.isRecording)
                            .opacity(0.12)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(sortedMessages) { msg in
                                        SiriMessageRow(
                                            message: msg,
                                            isStreaming: viewModel.isSending && msg.id == sortedMessages.last?.id,
                                            streamingText: viewModel.streamingText,
                                            onRetry: { viewModel.retryLast(conversation: conversation, context: context, appState: appState) },
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
                    }
                }

                // Thumbnail lampiran pending.
                if !pendingImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(pendingImages.indices, id: \.self) { i in
                                ZStack(alignment: .topTrailing) {
                                    if let ui = UIImage(data: pendingImages[i]) {
                                        Image(uiImage: ui)
                                            .resizable().scaledToFill()
                                            .frame(width: 64, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    Button {
                                        pendingImages.remove(at: i)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }
                }

                // Bottom bar: + | Ask Siri | mic/send.
                HStack(spacing: 12) {
                    Button { showPlusMenu.toggle() } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 56, height: 56)
                            .background(Circle().fill(Color(.systemGray6)))
                    }
                    .accessibilityLabel("Lampirkan")

                    TextField("Ask Siri", text: $inputText, axis: .vertical)
                        .focused($fieldFocused)
                        .lineLimit(1...4)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 28)
                                .fill(Color(.systemGray6))
                        )
                        .submitLabel(.send)
                        .onSubmit { send() }

                    Button { rightButtonAction() } label: {
                        Group {
                            if viewModel.isSending {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(Color.red))
                            } else if canSend {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(Color.accentColor))
                            } else if voice.isRecording {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(Color.red))
                            } else {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.primary)
                                    .frame(width: 56, height: 56)
                                    .background(Circle().fill(Color(.systemGray6)))
                            }
                        }
                    }
                    .accessibilityLabel(viewModel.isSending ? "Berhenti" : (canSend ? "Kirim" : "Suara"))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            // Popup menu + (Camera / Photos / Files) — seperti foto.
            if showPlusMenu {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { showPlusMenu = false }
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            plusRow(icon: "camera.fill", title: "Camera") {
                                showPlusMenu = false
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    showCamera = true
                                } else {
                                    alertText = "Kamera tidak tersedia di perangkat ini."
                                }
                            }
                            plusRow(icon: "photo.fill", title: "Photos") {
                                showPlusMenu = false
                                showPhotoPicker = true
                            }
                            plusRow(icon: "doc.fill", title: "Files") {
                                showPlusMenu = false
                                showFilePicker = true
                            }
                        }
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
                        )
                        .padding(.leading, 20)
                        .padding(.bottom, 96)
                        Spacer()
                    }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker(onPick: { addPickedImage($0) })
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker(onPick: { datas in
                for d in datas { addPickedImage(d) }
            })
        }
        .sheet(isPresented: $showFilePicker) {
            ImageFilePicker(onPick: { addPickedImage($0) })
        }
        .alert("Info", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        // STT → masuk ke text field.
        .onChange(of: voice.transcript) { _, t in
            if voice.isRecording || !t.isEmpty {
                inputText = t
            }
        }
        // Auto-speak: bacakan respons AI setelah selesai.
        .onChange(of: viewModel.isSending) { _, sending in
            if wasSending && !sending {
                wasSending = false
                speakIfEnabled()
            } else if sending {
                wasSending = true
                voice.stopSpeaking()
            }
        }
        .onChange(of: voice.permissionError) { _, e in
            if let e { alertText = e }
        }
        .onDisappear {
            viewModel.cancel()
            voice.stopRecording()
            voice.stopSpeaking()
        }
    }

    // MARK: - Aksi

    private func rightButtonAction() {
        if viewModel.isSending {
            viewModel.cancel()
            return
        }
        if canSend {
            send()
        } else {
            Task { @MainActor in
                if voice.isRecording {
                    voice.stopRecording()
                } else {
                    await voice.startRecording()
                }
            }
        }
    }

    @MainActor
    private func send() {
        if viewModel.isSending { viewModel.cancel(); return }
        let text = inputText
        let images = pendingImages
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        voice.stopSpeaking()
        viewModel.send(conversation: conversation, text: text,
                       imageDatas: images.map { ($0, false) }, note: nil,
                       context: context, appState: appState)
        inputText = ""
        pendingImages = []
        fieldFocused = false
    }

    private func addPickedImage(_ data: Data) {
        // Kecilkan dulu (max 1024px, JPEG) supaya upload vision cepat.
        if let jpeg = MediaService.downscaleJPEG(data) {
            pendingImages.append(jpeg)
        } else {
            pendingImages.append(data)
        }
    }

    @MainActor
    private func speakIfEnabled() {
        guard appState.autoSpeak else { return }
        let sorted = sortedMessages
        guard let last = sorted.last(where: { $0.role == "assistant" }),
              last.errorText == nil, !last.text.isEmpty else { return }
        voice.speak(last.text)
    }

    @ViewBuilder
    private func plusRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 28)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Orb Siri (aset SiriOrb), faint di tengah.

struct SiriOrbView: View {
    var animate: Bool = false
    @State private var pulse = false

    var body: some View {
        Image("SiriOrb")
            .resizable()
            .scaledToFill()
            .frame(width: 200, height: 200)
            .clipShape(Circle())
            .scaleEffect(pulse ? 1.06 : 1.0)
            .animation(pulse ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = animate }
            .onChange(of: animate) { _, a in pulse = a }
    }
}

// MARK: - Bubble pesan (75% lebar layar).

struct SiriMessageRow: View {
    let message: ChatMessage
    let isStreaming: Bool
    let streamingText: String
    let onRetry: () -> Void
    let onDelete: () -> Void

    private var maxBubbleWidth: CGFloat {
        min(UIScreen.main.bounds.width * 0.75, 520)
    }

    var body: some View {
        Group {
            if message.role == "user" {
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        if let first = message.images.first, let ui = UIImage(data: first.data) {
                            Image(uiImage: ui)
                                .resizable().scaledToFill()
                                .frame(width: 160, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        if !message.text.isEmpty {
                            Text(message.text)
                                .padding(12)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
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
                                Text(err).font(.caption).foregroundStyle(.red)
                                    .textSelection(.enabled)
                                Button("Coba lagi") { onRetry() }.font(.subheadline)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        } else {
                            let shown = (isStreaming && !streamingText.isEmpty) ? streamingText : message.text
                            if isStreaming && shown.isEmpty {
                                TypingIndicator()
                                    .padding(12)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else if shown.isEmpty {
                                Text("Respons kosong dari AI.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .padding(12)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                Text(shown)
                                    .textSelection(.enabled)
                                    .padding(12)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
}

// MARK: - Indikator "AI sedang mengetik".

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
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
