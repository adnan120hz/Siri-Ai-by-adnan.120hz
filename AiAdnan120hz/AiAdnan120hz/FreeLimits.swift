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
        let today = todayKey()
        guard let stored = d.string(forKey: dailyDateKey) else { return 0 }
        if stored == today { return d.integer(forKey: dailyCountKey) }
        if stored > today {
            // Jam perangkat dimundurkan (atau lintas garis tanggal ke barat)
            // setelah kuota dipakai: JANGAN beri kuota baru — pakai hitungan
            // tersimpan supaya limit harian tak bisa di-reset dengan memutar jam.
            // Perbandingan string aman karena format "yyyy-MM-dd" terurut
            // leksikografis sama seperti terurut kronologis.
            return d.integer(forKey: dailyCountKey)
        }
        return 0
    }

    static func canSendToday() -> Bool {
        todayCount() < maxPerDay
    }

    /// Catat 1 pesan user terkirim. Bila tanggal beda (maju) → reset ke 1.
    /// Bila tanggal tersimpan di masa depan (jam dimundurkan, lihat todayCount)
    /// → lanjutkan hitungan lama, jangan reset.
    /// Dipanggil sekali per pengiriman user yang lolos gate (lihat send()).
    static func recordSent() {
        let d = UserDefaults.standard
        let today = todayKey()
        let stored = d.string(forKey: dailyDateKey)
        let clockTurnedBack: Bool = {
            guard let stored else { return false }
            return stored > today
        }()
        if stored == today || clockTurnedBack {
            d.set(d.integer(forKey: dailyCountKey) + 1, forKey: dailyCountKey)
        } else {
            d.set(today, forKey: dailyDateKey)
            d.set(1, forKey: dailyCountKey)
        }
    }
}
