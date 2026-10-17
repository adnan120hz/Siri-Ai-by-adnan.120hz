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
// - allVoicesEnabled ("All voice menu") : UserDefaults key "siri.premium.allVoices"

import SwiftUI

/// Toggle fitur premium. Tiap toggle hanya efektif bila PremiumState.shared.isPremium.
/// Semua default MATI — user wajib aktifkan manual setelah redeem.
@MainActor
final class PremiumFeatures: ObservableObject {
    static let shared = PremiumFeatures()

    @Published var fileReadingEnabled: Bool = UserDefaults.standard.object(forKey: "siri.premium.fileReading") as? Bool ?? false {
        didSet { UserDefaults.standard.set(fileReadingEnabled, forKey: Self.fileReadingKey) }
    }
    @Published var allVoicesEnabled: Bool = UserDefaults.standard.object(forKey: "siri.premium.allVoices") as? Bool ?? false {
        didSet { UserDefaults.standard.set(allVoicesEnabled, forKey: Self.allVoicesKey) }
    }

    private static let fileReadingKey = "siri.premium.fileReading"
    private static let allVoicesKey = "siri.premium.allVoices"

    private init() {}
}
