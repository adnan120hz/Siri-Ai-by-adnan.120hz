import Foundation
import AVFoundation
import Speech

// MARK: - Voice: speech-to-text beneran (AVAudioRecorder → SFSpeechURLRecognitionRequest)
// dan text-to-speech beneran (AVSpeechSynthesizer). Bukan stub, bukan local fake.
//
// TIDAK pakai AVAudioEngine.installTap — rawan NSException (tidak bisa di-catch Swift)
// yang bikin force close. Rekam ke file .m4a dulu, lalu transcribe file.
//
// Anti-spam: state machine (idle → preparing → recording → transcribing → idle).
// Tap berkali-kali saat preparing/recording/transcribing = diabaikan, tidak crash.

// MARK: - Voice Model: 3 pilihan suara (Robot / Cowok / Cewek)

enum VoiceModel: String, CaseIterable, Identifiable {
    case robot
    case male    // Cowok
    case female  // Cewek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .robot: return "Robot"
        case .male: return "Cowok"
        case .female: return "Cewek"
        }
    }

    /// Pitch untuk tiap model (1.0 = normal).
    var pitch: Float {
        switch self {
        case .robot: return 0.7   // Rendah, monoton = robotik
        case .male: return 0.9    // Sedikit rendah = maskulin
        case .female: return 1.1  // Sedikit tinggi = feminin
        }
    }
}

@MainActor
final class VoiceService: ObservableObject {
    private enum Phase { case idle, preparing, recording, transcribing }

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var permissionError: String?

    private var phase: Phase = .idle
    /// Token untuk membatalkan persiapan yang masih in-flight (mis. dialog izin kebuka lalu user tap stop).
    private var preparingToken = UUID()

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

    /// Mulai merekam. Spam-tap aman: hanya jalan dari fase idle.
    /// Hasil masuk ke `transcript` setelah stop.
    func startRecording() async {
        // Guard anti-spam: tolak kalau bukan idle. Phase langsung preparing
        // SEBELUM await pertama, jadi tap kedua tidak bisa lolos.
        guard phase == .idle else { return }
        phase = .preparing
        let token = UUID()
        preparingToken = token
        print("[SiriAi] Voice: startRecording begin")

        // Guard 1: izin mic + speech (hanya minta kalau belum granted).
        if AVAudioSession.sharedInstance().recordPermission != .granted
            || SFSpeechRecognizer.authorizationStatus() != .authorized {
            print("[SiriAi] Voice: requesting permissions")
            guard await requestPermissions() else {
                print("[SiriAi] Voice: permissions denied")
                if phase == .preparing { phase = .idle }
                return
            }
            print("[SiriAi] Voice: permissions granted")
        }
        // Batal kalau user tap stop saat dialog izin masih kebuka.
        guard token == preparingToken, phase == .preparing else {
            print("[SiriAi] Voice: cancelled during permission")
            return
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
            phase = .idle
            return
        }
        print("[SiriAi] Voice: recognizer ready")

        // Guard 3: audio session.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            permissionError = "Gagal menyiapkan audio: \(error.localizedDescription)"
            phase = .idle
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
            deactivateSession()
            phase = .idle
            return
        }

        guard let recorder = audioRecorder, recorder.record() else {
            permissionError = "Gagal mulai merekam."
            audioRecorder = nil
            deactivateSession()
            phase = .idle
            return
        }

        // Cek terakhir sebelum go-live (user bisa tap stop di tengah jalan).
        guard token == preparingToken, phase == .preparing else {
            recorder.stop()
            audioRecorder = nil
            deactivateSession()
            return
        }

        transcript = ""
        phase = .recording
        isRecording = true
    }

    /// Stop merekam lalu transcribe file. Aman dipanggil berkali-kali.
    func stopRecording() {
        switch phase {
        case .idle, .transcribing:
            return
        case .preparing:
            // Batalkan persiapan in-flight (dialog izin masih kebuka).
            preparingToken = UUID()
            phase = .idle
        case .recording:
            phase = .transcribing
            isRecording = false
            audioRecorder?.stop()
            audioRecorder = nil
            deactivateSession()
            transcribeFile()
        }
    }

    /// Batalkan recognition task dengan aman (cancel + nil). Dipanggil sebelum task baru.
    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func transcribeFile() {
        cancelRecognition()
        let url = recordingURL
        // Pastikan file ada dan tidak kosong — jangan transcribe file hantu.
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > 0 else {
            phase = .idle
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            phase = .idle
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
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
                self.phase = .idle
            }
        }
    }

    private func deactivateSession() {
        // Jangan nonaktifkan saat TTS lagi ngomong.
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Text-to-speech

    /// Bacakan teks dengan suara sistem (id-ID kalau tersedia).
    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopSpeaking()
        // Jangan utak-atik audio session saat lagi merekam — recorder bisa keganggu.
        if phase != .recording {
            do {
                // Pakai playback agar suara keluar walau silent switch nyala.
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                // Tetap coba speak tanpa session khusus.
            }
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
