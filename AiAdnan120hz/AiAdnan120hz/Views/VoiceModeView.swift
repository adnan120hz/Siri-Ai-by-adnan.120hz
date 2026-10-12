import SwiftUI
import SwiftData

// MARK: - Mode Suara: tahan tombol mic → bicara → kirim → jawaban dibacakan.
// Label jujur: loop STT → AI → TTS, bukan realtime duplex.

struct VoiceModeView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()
    @StateObject private var viewModel = ChatViewModel()
    @State private var permissionDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Text("Mode Suara")
                        .font(.title2).bold()
                    Text("STT → AI → TTS (bukan realtime duplex)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.top)

                ScrollView {
                    Text(speech.transcript.isEmpty ? "Tahan tombol mic, lalu bicara…" : speech.transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxHeight: 220)

                if let status = speech.statusMessage {
                    Text(status).font(.footnote).foregroundStyle(.red)
                }
                if permissionDenied {
                    Text("Izin mic / speech recognition ditolak. Aktifkan di Pengaturan iPhone → Privasi.")
                        .font(.footnote).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task { @MainActor in
                        if speech.isRecording { speech.stopRecording() }
                        else { speech.startRecording() }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(speech.isRecording ? .red : .accentColor)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { Task { @MainActor in close() } }
                }
            }
        }
        .onAppear {
            Task {
                let ok = await speech.requestPermissions()
                if !ok { permissionDenied = true }
            }
        }
        .onDisappear { Task { @MainActor in close() } }
    }

    @MainActor
    private func sendVoice() {
        let text = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        speech.transcript = ""
        viewModel.send(conversation: conversation, text: text, imageDatas: [],
                       note: "via Mode Suara", context: context, appState: appState)
        Task {
            while await MainActor.run({ viewModel.isSending }) {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            let reply = await MainActor.run {
                conversation.messages.sorted { $0.createdAt < $1.createdAt }
                    .last(where: { $0.role == "assistant" && !$0.text.isEmpty })
            }
            if let reply {
                await MainActor.run { speech.speak(reply.text) }
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
