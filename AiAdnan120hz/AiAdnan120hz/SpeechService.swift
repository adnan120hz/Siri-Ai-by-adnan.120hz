import Foundation
import AVFoundation

// MARK: - Mode Suara: rekam mic → STT via APInex → AI → TTS via APInex.
// STT/TTS 100% via API (cloud), BUKAN on-device — sesuai perintah user.
// Mic tetap direkam lokal dulu (wajib), yang "cloud" adalah recognition & synthesis.

@MainActor
final class SpeechService: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var isSpeaking = false
    @Published var isTranscribing = false
    @Published var statusMessage: String?

    /// Preferensi suara (disimpan). pace/expressivity: 0...1.
    @Published var pace: Double = UserDefaults.standard.double(forKey: "siriVoice.pace").nonZeroOr(0.5)
    @Published var expressivity: Double = UserDefaults.standard.double(forKey: "siriVoice.expressivity").nonZeroOr(0.5)
    /// Index suara cloud terpilih (0...4). -1 = default.
    @Published var voiceIndex: Int = UserDefaults.standard.integer(forKey: "siriVoice.index") - 1
    @Published var accent: String = UserDefaults.standard.string(forKey: "siriVoice.accent") ?? "id-ID"

    /// Suara cloud (standar OpenAI-compatible).
    static let cloudVoices = ["alloy", "echo", "fable", "onyx", "nova"]

    var selectedCloudVoice: String {
        let vs = Self.cloudVoices
        return (voiceIndex >= 0 && voiceIndex < vs.count) ? vs[voiceIndex] : vs[0]
    }

    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var audioPlayer: AVAudioPlayer?

    func saveVoicePrefs() {
        let d = UserDefaults.standard
        d.set(pace, forKey: "siriVoice.pace")
        d.set(expressivity, forKey: "siriVoice.expressivity")
        d.set(voiceIndex + 1, forKey: "siriVoice.index")
        d.set(accent, forKey: "siriVoice.accent")
    }

    // MARK: - Permission (mic saja; speech-recognition tidak dipakai lagi)

    func requestPermissions() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
        }
    }

    // MARK: - Rekam → file WAV

    func startRecording() {
        guard !isRecording else { return }
        transcript = ""
        statusMessage = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "Audio: \(error.localizedDescription)"
            return
        }
        guard session.isInputAvailable else {
            statusMessage = "Mic tidak tersedia saat ini (mungkin dipakai app lain)."
            try? session.setActive(false)
            return
        }

        isRecording = true
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_\(UUID().uuidString).wav")
        recordingURL = url
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0) // defensif
        let format = input.outputFormat(forBus: 0)
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            input.removeTap(onBus: 0)
            isRecording = false
            try? session.setActive(false)
            statusMessage = "Rekam: \(error.localizedDescription)"
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            isRecording = false
            try? session.setActive(false)
            statusMessage = "Mic: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        // Otomatis transkripsi via API setelah rekaman berhenti.
        if let url = recordingURL {
            recordingURL = nil
            transcribe(url: url)
        }
    }

    // MARK: - STT via APInex (/v1/audio/transcriptions)

    private func transcribe(url: URL) {
        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            statusMessage = "API key belum dipasang."
            return
        }
        isTranscribing = true
        statusMessage = nil
        Task { @MainActor in
            do {
                let text = try await APInexClient.transcribeAudio(apiKey: apiKey, audioURL: url,
                                                                  language: sttLanguage)
                await MainActor.run {
                    self.transcript = text
                    self.isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isTranscribing = false
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private var sttLanguage: String {
        accent.components(separatedBy: "-").first?.lowercased() ?? "id"
    }

    // MARK: - TTS via APInex (/v1/audio/speech)

    func speak(_ text: String) {
        stopSpeaking()
        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            statusMessage = "API key belum dipasang."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSpeaking = true
        // pace 0...1 → speed 0.7...1.3 ; expressivity → instruksi gaya bicara
        let speed = 0.7 + pace * 0.6
        let style: String?
        if expressivity > 0.66 {
            style = "Speak with high expressiveness and energy."
        } else if expressivity < 0.33 {
            style = "Speak calmly and neutrally."
        } else {
            style = nil
        }
        Task { @MainActor in
            do {
                let data = try await APInexClient.synthesizeSpeech(apiKey: apiKey, text: trimmed,
                                                                   voice: selectedCloudVoice,
                                                                   speed: speed, style: style)
                await MainActor.run {
                    do {
                        let player = try AVAudioPlayer(data: data)
                        self.audioPlayer = player
                        player.play()
                        // Tandai selesai saat audio habis.
                        Task { @MainActor in
                            while self.audioPlayer?.isPlaying == true {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                            }
                            self.isSpeaking = false
                        }
                    } catch {
                        self.statusMessage = "Audio: \(error.localizedDescription)"
                        self.isSpeaking = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isSpeaking = false
                }
            }
        }
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
    }
}

private extension Double {
    /// UserDefaults.double mengembalikan 0 untuk key yang belum ada —
    /// bedakan "belum diatur" dari "diatur ke 0".
    func nonZeroOr(_ fallback: Double) -> Double {
        self == 0 ? fallback : self
    }
}
