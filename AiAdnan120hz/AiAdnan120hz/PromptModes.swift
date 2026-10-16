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

    /// Nama tampilan untuk UI (Bahasa Indonesia).
    var displayName: String {
        switch self {
        case .gaul: return "Gaul"
        case .formal: return "Formal"
        case .santai: return "Santai"
        case .custom: return "Custom"
        }
    }

    /// Instruksi sistem untuk gaya bicara mode ini (Bahasa Indonesia).
    ///
    /// Agen integrasi menggabungkan nilai ini ke `systemInstruction` yang
    /// dikirim ke `GeminiClient.sendText(...)`. String kosong = tidak ada
    /// tambahan; instruksi dasar Siri tetap berlaku.
    func systemInstruction() -> String {
        switch self {
        case .gaul:
            return "Bicaralah dengan gaya gaul yang santai dan natural: pakai bahasa sehari-hari Indonesia seperti dipakai anak muda, tapi tetap jelas dan mudah dipahami. Jangan lebay atau alay. Tetap ikuti aturan panjang jawaban dasar."
        case .formal:
            return "Bicaralah dengan gaya formal yang baku dan sopan: gunakan bahasa Indonesia yang baik dan benar, susunan kalimat rapi, nada profesional. Tetap ikuti aturan panjang jawaban dasar."
        case .santai:
            return "Bicaralah dengan gaya santai yang hangat dan ringan: ramah, tidak kaku, seperti ngobrol dengan teman akrab, tapi jangan sampai nyablak atau asal. Tetap ikuti aturan panjang jawaban dasar."
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
