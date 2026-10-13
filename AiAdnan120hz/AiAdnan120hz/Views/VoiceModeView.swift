import SwiftUI
import SwiftData

// MARK: - Mode Suara ala Siri: orb besar di tengah, tahan/ketuk mic untuk bicara.
// Label jujur: loop STT → AI → TTS, bukan realtime duplex.

struct VoiceModeView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()
    @StateObject private var viewModel = ChatViewModel()
    @State private var permissionDenied = false
    @State private var showVoiceSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                SiriBackground()
                VStack(spacing: 16) {
                    // Orb — membesar saat merekam
                    Button {
                        Task { @MainActor in toggleRecord() }
                    } label: {
                        SiriOrbView(size: speech.isRecording ? 240 : 200)
                            .animation(.easeInOut(duration: 0.3), value: speech.isRecording)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)

                    Text(speech.isRecording ? "Mendengarkan…" : "Ketuk orb untuk bicara")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        Text(speech.transcript.isEmpty ? "" : speech.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(maxHeight: 140)

                    if let status = speech.statusMessage {
                        Text(status).font(.footnote).foregroundStyle(.red)
                    }
                    if permissionDenied {
                        Text("Izin mic ditolak. Aktifkan di Pengaturan iPhone → Privasi → Mikrofon.")
                            .font(.footnote).foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if speech.isTranscribing {
                        ProgressView("Mengubah suara jadi teks…")
                    }

                    Button("Kirim ke AI") { Task { @MainActor in sendVoice() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSending)

                    if viewModel.isSending {
                        ProgressView("AI menjawab…")
                    }
                    if speech.isSpeaking {
                        Button("Berhenti bicara") { Task { @MainActor in speech.stopSpeaking() } }
                            .font(.subheadline)
                    }

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Mode Suara")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { Task { @MainActor in close() } }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showVoiceSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Kustomisasi suara")
                }
            }
            .sheet(isPresented: $showVoiceSettings) {
                NavigationStack { SiriVoiceSettingsView() }
            }
        }
        .onAppear {
            Task { @MainActor in
                let ok = await speech.requestPermissions()
                if !ok { permissionDenied = true }
            }
        }
        .onDisappear { Task { @MainActor in close() } }
    }

    @MainActor
    private func toggleRecord() {
        if speech.isRecording { speech.stopRecording() }
        else { speech.startRecording() }
    }

    @MainActor
    private func sendVoice() {
        let text = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speech.transcript = ""
        viewModel.send(conversation: conversation, text: text, imageDatas: [],
                       note: "via Mode Suara", context: context, appState: appState)
        Task { @MainActor in
            while viewModel.isSending {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            if let reply = conversation.messages.sorted(by: { $0.createdAt < $1.createdAt })
                .last(where: { $0.role == "assistant" && !$0.text.isEmpty }) {
                speech.speak(reply.text)
            }
        }
    }

    @MainActor
    private func close() {
        speech.stopRecording()
        speech.stopSpeaking()
        viewModel.cancel()
        dismiss()
    }
}
