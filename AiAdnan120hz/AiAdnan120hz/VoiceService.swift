import Foundation
import AVFoundation
import Speech

// MARK: - Voice: speech-to-text beneran (SFSpeechRecognizer + AVAudioEngine)
// dan text-to-speech beneran (AVSpeechSynthesizer). Bukan stub, bukan local fake.

@MainActor
final class VoiceService: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var permissionError: String?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Izin

    /// Minta izin microphone + speech recognition. Kembalikan true kalau keduanya granted.
    func requestPermissions() async -> Bool {
        // 1. Microphone
        let micGranted = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        guard micGranted else {
            permissionError = "Izin mikrofon ditolak. Nyalakan di Pengaturan iPhone → Siri Ai → Mikrofon."
            return false
        }
        // 2. Speech recognition
        let speechStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            permissionError = "Izin speech recognition ditolak. Nyalakan di Pengaturan iPhone → Siri Ai → Speech Recognition."
            return false
        }
        permissionError = nil
        return true
    }

    // MARK: - Speech-to-text

    /// Mulai merekam. Hasil partial/full masuk ke `transcript` (dipakai view untuk isi text field).
    func startRecording() async {
        guard !isRecording else { return }
        guard await requestPermissions() else { return }

        // Batalkan task lama kalau ada.
        stopAudioEngine()

        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "id-ID")) ?? SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            permissionError = "Speech recognizer tidak tersedia saat ini (butuh internet)."
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            permissionError = "Gagal menyiapkan audio: \(error.localizedDescription)"
            return
        }

        transcript = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            permissionError = "Gagal mulai merekam: \(error.localizedDescription)"
            return
        }

        isRecording = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                // Berhenti otomatis saat hasil final atau error.
                if error != nil || (result?.isFinal ?? false) {
                    self.stopRecording()
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        stopAudioEngine()
        isRecording = false
        // Kembalikan audio session agar TTS / audio lain jalan normal.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
    }

    // MARK: - Text-to-speech

    /// Bacakan teks dengan suara sistem (id-ID kalau tersedia).
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopSpeaking()
        do {
            // Pakai playback agar suara keluar walau silent switch nyala.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Tetap coba speak tanpa session khusus.
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: "id-ID")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }
}
