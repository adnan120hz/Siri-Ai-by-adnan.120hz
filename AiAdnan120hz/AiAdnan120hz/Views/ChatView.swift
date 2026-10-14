import SwiftUI
import SwiftData


// MARK: - Chat screen. Pixel-matched to the Siri iOS 27 reference:
// white background, X/chevron top-left, faint orb on empty state,
// gray user bubbles right, plain AI text left, spinner loading,
// bottom bar: + | "Ask Siri" | mic -> black send -> red stop.

struct ChatView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var voice = VoiceService()

    let conversation: Conversation
    var openedFromHistory: Bool = false
    @Binding var showConversations: Bool

    @State private var inputText = ""
    @State private var pendingImages: [Data] = []
    @State private var showPlusMenu = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFilePicker = false
    @State private var alertText: String?
    @State private var wasSending = false
    @FocusState private var fieldFocused: Bool

    private var messages: [ChatMessage] {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top-left: X for new chat, chevron when opened from history.
            HStack {
                SiriCircleButton(
                    systemImage: openedFromHistory ? "chevron.left" : "xmark",
                    imageSize: 20
                ) {
                    showConversations = true
                }
                .accessibilityLabel(openedFromHistory ? Text("Back") : Text("Close"))
                Spacer()
            }
            .padding(.horizontal, SiriTheme.m)
            .padding(.top, SiriTheme.s)

            // Messages.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: SiriTheme.m) {
                        if messages.isEmpty {
                            SiriOrbFaint(animate: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, 120)
                        } else {
                            ForEach(messages) { msg in
                                MessageRow(
                                    message: msg,
                                    isStreaming: viewModel.isSending && msg.role == "assistant",
                                    streamingText: viewModel.streamingText,
                                    onRetry: { retry(msg) },
                                    onDelete: {
                                        context.delete(msg)
                                        try? context.save()
                                    }
                                )
                                .id(msg.id)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                            }
                            if viewModel.isSending && viewModel.streamingText.isEmpty {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Spacer()
                                }
                                .padding(.leading, SiriTheme.m)
                            }
                        }
                    }
                    .padding(.horizontal, SiriTheme.m)
                    .padding(.top, SiriTheme.s)
                }
                .animation(SiriTheme.conversational, value: messages.count)
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation(SiriTheme.composerGrow) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: viewModel.streamingText) { _, _ in
                    if let last = messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Spacer(minLength: 0)

            // Pending attachments strip.
            if !pendingImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: SiriTheme.s) {
                        ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, data in
                            ZStack(alignment: .topTrailing) {
                                if let ui = UIImage(data: data) {
                                    Image(uiImage: ui)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                Button {
                                    pendingImages.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.primary, Color(.systemBackground))
                                }
                                .offset(x: 6, y: -6)
                                .accessibilityLabel(Text("Remove attachment"))
                            }
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, SiriTheme.m)
                    .padding(.vertical, SiriTheme.s)
                    .animation(SiriTheme.pop, value: pendingImages.count)
                }
            }

            // Bottom bar.
            HStack(spacing: 10) {
                SiriCircleButton(systemImage: "plus", imageSize: 24) {
                    withAnimation(SiriTheme.pop) { showPlusMenu.toggle() }
                }
                .accessibilityLabel(Text("Attach"))

                TextField("Ask Siri", text: $inputText, axis: .vertical)
                    .focused($fieldFocused)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .padding(.horizontal, 18)
                    .padding(.vertical, SiriTheme.m)
                    .background(
                        RoundedRectangle(cornerRadius: SiriTheme.inputCorner, style: .continuous)
                            .fill(SiriTheme.inputFill)
                    )
                    .animation(SiriTheme.composerGrow, value: inputText)

                rightButton
            }
            .padding(.horizontal, SiriTheme.m)
            .padding(.vertical, 12)
            .animation(SiriTheme.keyboard, value: fieldFocused)
        }
        .background(Color(.systemBackground))
        .overlay(plusMenuOverlay)
        .sheet(isPresented: $showCamera) {
            CameraPicker { addPickedImage($0) }
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { datas in
                for d in datas { addPickedImage(d) }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            MediaFilePicker { datas in
                for d in datas { addPickedImage(d) }
            }
        }
        .alert("Info", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText ?? "")
        }
        // STT -> text field, live.
        .onChange(of: voice.transcript) { _, t in
            if voice.isRecording || !t.isEmpty { inputText = t }
        }
        // Auto-speak when the answer finishes.
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
        .onChange(of: viewModel.lastError) { _, e in
            if let e { alertText = e }
        }
        .onDisappear {
            viewModel.cancel()
            voice.stopRecording()
            voice.stopSpeaking()
        }
    }

    // MARK: - Right button: mic -> black send -> red stop.

    @ViewBuilder
    private var rightButton: some View {
        Button { rightButtonAction() } label: {
            ZStack {
                if viewModel.isSending {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                        .background(Circle().fill(Color.red))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if canSend {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                        .background(Circle().fill(Color.black))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else if voice.isRecording {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                        .background(Circle().fill(Color.red))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.primary)
                        .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                        .background(Circle().fill(SiriTheme.circleFill))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(SiriTheme.snappy, value: canSend)
            .animation(SiriTheme.snappy, value: viewModel.isSending)
            .animation(SiriTheme.snappy, value: voice.isRecording)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: canSend)
        .accessibilityLabel(viewModel.isSending ? Text("Stop") : (canSend ? Text("Send") : Text("Voice")))
    }

    // MARK: - + attachment menu.

    @ViewBuilder
    private var plusMenuOverlay: some View {
        if showPlusMenu {
            ZStack(alignment: .bottomLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(SiriTheme.pop) { showPlusMenu = false }
                    }
                VStack(alignment: .leading, spacing: 0) {
                    plusRow(icon: "camera.fill", title: "Camera") {
                        dismissMenu()
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCamera = true
                        } else {
                            alertText = "Camera is not available on this device."
                        }
                    }
                    plusRow(icon: "photo.fill.on.rectangle.fill", title: "Photos") {
                        dismissMenu(); showPhotoPicker = true
                    }
                    plusRow(icon: "doc.fill", title: "Files") {
                        dismissMenu(); showFilePicker = true
                    }
                }
                .padding(.vertical, SiriTheme.s)
                .background(
                    RoundedRectangle(cornerRadius: SiriTheme.menuCorner, style: .continuous)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.15), radius: 16, y: 4)
                )
                .padding(.leading, SiriTheme.m)
                .padding(.bottom, 92)
                // Pop from the + button: scale from bottom-leading corner.
                .scaleEffect(1, anchor: .bottomLeading)
                .transition(.scale(scale: 0.85, anchor: .bottomLeading).combined(with: .opacity))
            }
            .zIndex(1)
        }
    }

    private func plusRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .frame(width: 28)
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, SiriTheme.m)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dismissMenu() {
        withAnimation(SiriTheme.pop) { showPlusMenu = false }
    }

    // MARK: - Actions.

    private func rightButtonAction() {
        if viewModel.isSending { viewModel.cancel(); return }
        if canSend {
            send()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            Task { @MainActor in
                if voice.isRecording { voice.stopRecording() }
                else { await voice.startRecording() }
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
        viewModel.send(
            conversation: conversation, text: text,
            imageDatas: images.map { ($0, false) }, note: nil,
            context: context, appState: appState
        )
        inputText = ""
        pendingImages = []
        fieldFocused = false
    }

    private func retry(_ message: ChatMessage) {
        // Jangan kirim ulang teks pesan assistant (kosong saat error) —
        // retryLast mengambil pesan user sebelumnya yang benar.
        message.errorText = nil
        try? context.save()
        viewModel.retryLast(conversation: conversation, context: context, appState: appState)
    }

    private func addPickedImage(_ data: Data) {
        if let jpeg = MediaService.downscaleJPEG(data) {
            pendingImages.append(jpeg)
        } else {
            pendingImages.append(data)
        }
    }

    @MainActor
    private func speakIfEnabled() {
        guard appState.autoSpeak else { return }
        guard let last = messages.last(where: { $0.role == "assistant" }),
              last.errorText == nil, !last.text.isEmpty else { return }
        voice.speak(last.text)
    }
}

// MARK: - Message row: user bubble right, AI plain text left.

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
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !message.images.isEmpty {
                            if message.images.count == 1,
                               let first = message.images.first,
                               let ui = UIImage(data: first.data) {
                                Image(uiImage: ui)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 160, height: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, img in
                                            if let ui = UIImage(data: img.data) {
                                                Image(uiImage: ui)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 100, height: 100)
                                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !message.text.isEmpty {
                            Text(message.text)
                                .font(.body)
                                .padding(.horizontal, 12)
                                .padding(.vertical, SiriTheme.s)
                                .background(
                                    RoundedRectangle(cornerRadius: SiriTheme.bubbleCorner, style: .continuous)
                                        .fill(SiriTheme.userBubble)
                                )
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        if let err = message.errorText, !err.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Failed", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline)
                                    .foregroundStyle(.red)
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                Button("Try again", action: onRetry)
                                    .font(.subheadline)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: SiriTheme.bubbleCorner, style: .continuous))
                        } else {
                            let shown = (isStreaming && !streamingText.isEmpty) ? streamingText : message.text
                            if shown.isEmpty {
                                Text("Empty response from AI.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                // Plain text, no bubble — matches Siri reference.
                                Text(shown)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Spacer(minLength: 48)
                }
            }
        }
        .contextMenu {
            Button("Delete message", role: .destructive, action: onDelete)
            if message.role == "assistant", message.errorText != nil {
                Button("Try again", action: onRetry)
            }
        }
    }
}
