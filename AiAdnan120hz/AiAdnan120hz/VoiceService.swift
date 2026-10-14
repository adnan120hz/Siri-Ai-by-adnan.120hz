import Foundation
import AVFoundation
import Speech

// MARK: - Voice: speech-to-text beneran (AVAudioRecorder → SFSpeechURLRecognitionRequest)
// dan text-to-speech beneran (AVSpeechSynthesizer). Bukan stub, bukan local fake.
//
// TIDAK pakai AVAudioEngine.installTap — rawan NSException (tidak bisa di-catch Swift)
// yang bikin force close. Rekam ke file .m4a dulu, lalu transcribe file.

@MainActor
final class VoiceService: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    @Published var permissionError: String?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioRecorder: AVAudioRecorder?

    private let synthesizer = AVSpeechSynthesizer()

    private var recordingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voice_input.m4a")
    }

    // MARK: - Izin

    /// Minta izin microphone + speech recognition. Kembalikan true kalau keduanya granted.
    func requestPermissions() async -> Bool {
        // Cek cepat status saat ini — kalau sudah denied, langsung alert tanpa request ulang.
        if AVAudioSession.sharedInstance().recordPermission == .denied {
            permissionError = "Izin mikrofon ditolak. Nyalakan di Pengaturan iPhone → Siri Ai → Mikrofon."
            return false
        }
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
        if SFSpeechRecognizer.authorizationStatus() == .denied
            || SFSpeechRecognizer.authorizationStatus() == .restricted {
            permissionError = "Speech recognition dibatasi/ditolak di perangkat ini. Cek Pengaturan iPhone → Siri Ai."
            return false
        }
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

    // MARK: - Speech-to-text (via AVAudioRecorder → file → SFSpeechURLRecognitionRequest)
    //
    // TIDAK pakai AVAudioEngine.installTap — rawan NSException (tidak bisa di-catch Swift).
    // Rekam ke file .m4a, lalu transcribe file. Jauh lebih stabil.

    /// Mulai merekam. Hasil masuk ke `transcript` setelah stop.
    func startRecording() async {
        guard !isRecording else { return }

        // Guard 1: izin mic + speech.
        if AVAudioSession.sharedInstance().recordPermission != .granted {
            guard await requestPermissions() else { return }
        } else {
            let s = SFSpeechRecognizer.authorizationStatus()
            if s != .authorized {
                guard await requestPermissions() else { return }
            }
        }

        // Guard 2: locale.
        let locale = Locale(identifier: "id-ID")
        if SFSpeechRecognizer.supportedLocales().contains(locale) {
            recognizer = SFSpeechRecognizer(locale: locale)
        } else {
            recognizer = SFSpeechRecognizer()
        }
        guard let recognizer, recognizer.isAvailable else {
            permissionError = "Speech recognizer tidak tersedia saat ini (butuh internet)."
            return
        }

        // Guard 3: audio session.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            permissionError = "Gagal menyiapkan audio: \(error.localizedDescription)"
            return
        }

        // Hapus file lama kalau ada.
        try? FileManager.default.removeItem(at: recordingURL)

        // Guard 4: buat recorder.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            audioRecorder = try AVAudioRecorder(url: recordingURL, settings: settings)
        } catch {
            permissionError = "Gagal mulai merekam: \(error.localizedDescription)"
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        guard let recorder = audioRecorder, recorder.record() else {
            permissionError = "Gagal mulai merekam."
            audioRecorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return
        }

        transcript = ""
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        audioRecorder?.stop()
        audioRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        // Transcribe file yang baru direkam.
        guard let recognizer else { return }
        let request = SFSpeechURLRecognitionRequest(url: recordingURL)
        request.shouldReportPartialResults = false
        recognitionTask?.cancel()
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil {
                    // Diam — transcript tetap kosong, user bisa ketik manual.
                }
                self.recognitionTask = nil
            }
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
