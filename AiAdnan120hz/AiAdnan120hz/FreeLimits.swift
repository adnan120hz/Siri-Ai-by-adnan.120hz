import Foundation

// MARK: - Free tier limits: 20 pesan user per chat, 40 pesan user per hari.
// Definisi "1 pesan" = 1 pesan user yang berhasil dikirim (bukan balasan AI).
// Premium (PremiumState.shared.isPremium) melewati kedua limit.
// Pesan lama tidak pernah dihapus otomatis.

enum FreeLimits {
    static let maxPerChat = 20
    static let maxPerDay = 40

    private static let dailyCountKey = "siri.free.dailyCount"
    private static let dailyDateKey = "siri.free.dailyDate"

    // MARK: - Per-chat

    /// Jumlah pesan role "user" di conversation ini. Dihitung ulang dari
    /// model — kalau user menghapus pesan manual, slot ikut kembali.
    static func userMessageCount(in conversation: Conversation) -> Int {
        conversation.messages.filter { $0.role == "user" }.count
    }

    static func canSendInChat(conversation: Conversation) -> Bool {
        userMessageCount(in: conversation) < maxPerChat
    }

    // MARK: - Per-hari (UserDefaults, reset saat tanggal lokal berganti)

    /// Tanggal lokal "yyyy-MM-dd". Posix locale supaya format stabil.
    private static func todayKey() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    static func todayCount() -> Int {
        let d = UserDefaults.standard
        guard d.string(forKey: dailyDateKey) == todayKey() else { return 0 }
        return d.integer(forKey: dailyCountKey)
    }

    static func canSendToday() -> Bool {
        todayCount() < maxPerDay
    }

    /// Catat 1 pesan user terkirim. Bila tanggal beda → reset ke 1.
    /// Dipanggil sekali per pengiriman user yang lolos gate (lihat send()).
    static func recordSent() {
        let d = UserDefaults.standard
        let today = todayKey()
        if d.string(forKey: dailyDateKey) == today {
            d.set(d.integer(forKey: dailyCountKey) + 1, forKey: dailyCountKey)
        } else {
            d.set(today, forKey: dailyDateKey)
            d.set(1, forKey: dailyCountKey)
        }
    }
}
