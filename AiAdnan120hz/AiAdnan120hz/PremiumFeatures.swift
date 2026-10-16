// PremiumFeatures.swift
//
// KONTRAK FINAL — toggle fitur premium aplikasi.
// Agen lain membaca file ini; JANGAN ubah nama class, property, atau API publik.
//
// Tiap toggle hanya EFEKTIF bila PremiumState.shared.isPremium.
// Semua default MATI — user wajib mengaktifkan manual setelah redeem.
//
// Penyimpanan:
// - fileReadingEnabled : UserDefaults key "siri.premium.fileReading"
// - usePremiumKey ("Other API Key") : UserDefaults key "siri.premium.usePremiumKey"

import SwiftUI

/// Toggle fitur premium. Tiap toggle hanya efektif bila PremiumState.shared.isPremium.
/// Semua default MATI — user wajib aktifkan manual setelah redeem.
final class PremiumFeatures: ObservableObject {
    static let shared = PremiumFeatures()

    @Published var fileReadingEnabled: Bool = UserDefaults.standard.object(forKey: Self.fileReadingKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(fileReadingEnabled, forKey: Self.fileReadingKey) }
    }
    @Published var usePremiumKey: Bool = UserDefaults.standard.object(forKey: Self.usePremiumKeyKey) as? Bool ?? false {
        didSet { UserDefaults.standard.set(usePremiumKey, forKey: Self.usePremiumKeyKey) }
    }

    private static let fileReadingKey = "siri.premium.fileReading"
    private static let usePremiumKeyKey = "siri.premium.usePremiumKey"

    private init() {}
}
