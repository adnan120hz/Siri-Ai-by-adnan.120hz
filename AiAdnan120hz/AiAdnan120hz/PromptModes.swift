// PromptModes.swift
//
// KONTRAK FINAL — prompt mode premium untuk gaya bicara AI.
// Agen lain membaca file ini; JANGAN ubah nama enum, case, atau API publik.
//
// Mode ini HANYA melapisi GAYA bicara, bukan isi. Instruksi dasar Siri
// (cool/dingin, maks 2–3 kalimat, tanpa emoji/markdown) tetap berlaku penuh.
// Tiap instruksi di bawah eksplisit memerintahkan untuk tetap mengikuti
// aturan panjang jawaban dasar.
//
// Penyimpanan:
// - Mode terpilih : UserDefaults key "siri.prompt.mode" (rawValue String, default .santai)
// - Teks custom   : UserDefaults key "siri.prompt.customText"

import Foundation

/// Gaya bicara AI yang bisa dipilih user premium.
enum PromptMode: String, Codable, CaseIterable {
    case gaul
    case formal
    case santai
    case custom

    /// Display name for the UI (kept as-is; these are feature names).
    var displayName: String {
        switch self {
        case .gaul: return "Gaul"
        case .formal: return "Formal"
        case .santai: return "Santai"
        case .custom: return "Custom"
        }
    }

    /// System instruction for this mode's speaking style (English).
    ///
    /// The integration layer merges this into the `systemInstruction` sent
    /// to `GroqClient.sendText(...)`. Empty string = no extra instruction;
    /// the base Siri instruction still applies.
    func systemInstruction() -> String {
        switch self {
        case .gaul:
            return "Speak in a casual, natural slang style: use everyday Indonesian like young people do, but stay clear and easy to understand. Don't overdo it. Still follow the base answer-length rules."
        case .formal:
            return "Speak in a standard, polite formal style: use proper, correct Indonesian with neat sentence structure and a professional tone. Still follow the base answer-length rules."
        case .santai:
            return "Speak in a warm, light, relaxed style: friendly, not stiff, like chatting with a close friend, but don't get crude or sloppy. Still follow the base answer-length rules."
        case .custom:
            // Teks custom user; kosong = tidak ada tambahan (fallback ke "" dan dokumentasikan di bawah).
            return PromptMode.customText
        }
    }

    // MARK: - Persistensi

    private static let modeKey = "siri.prompt.mode"
    private static let customTextKey = "siri.prompt.customText"

    /// Mode yang sedang terpilih. Default: .santai.
    static var selected: PromptMode {
        get {
            let raw = UserDefaults.standard.string(forKey: modeKey)
            return raw.flatMap(PromptMode.init(rawValue:)) ?? .santai
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: modeKey)
        }
    }

    /// Teks instruksi custom yang ditulis user (khusus mode .custom).
    ///
    /// Perilaku saat kosong: `systemInstruction()` untuk .custom mengembalikan
    /// string kosong, artinya tidak ada instruksi gaya tambahan sama sekali —
    /// AI menjawab hanya dengan instruksi dasar Siri. (Dipilih sengaja: lebih
    /// jujur daripada diam-diam menimpa dengan mode santai.)
    static var customText: String {
        get {
            UserDefaults.standard.string(forKey: customTextKey) ?? ""
        }
        set {
            UserDefaults.standard.set(newValue, forKey: customTextKey)
        }
    }
}
