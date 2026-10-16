// PremiumState.swift
//
// KONTRAK FINAL — singleton state premium aplikasi.
// Agen lain membaca file ini; JANGAN ubah nama class, property, atau API publik.
//
// Status premium dibaca/ditulis ke UserDefaults dengan key "siri.premium.redeemed".

import SwiftUI

@MainActor
final class PremiumState: ObservableObject {

    static let shared = PremiumState()

    @Published private(set) var isPremium: Bool = false

    private static let redeemedKey = "siri.premium.redeemed"

    private init() {
        self.isPremium = UserDefaults.standard.bool(forKey: Self.redeemedKey)
    }

    /// Set status premium (dipanggil setelah redeem code valid).
    /// Aman dipanggil dari thread mana pun; update @Published selalu di main thread.
    func setRedeemed(_ redeemed: Bool) {
        UserDefaults.standard.set(redeemed, forKey: Self.redeemedKey)
        if Thread.isMainThread {
            isPremium = redeemed
        } else {
            DispatchQueue.main.async { self.isPremium = redeemed }
        }
    }
}
