import Foundation

// MARK: - Pelacak pemakaian token harian (estimasi lokal, Gemini).
// Reset otomatis tiap ganti hari. Estimasi kasar: 1 token ≈ 4 karakter.

enum TokenUsage {
    static let dailyCap = 10_000_000

    private static let dateKey = "tokenUsage.date"
    private static let countKey = "tokenUsage.count"

    private static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }

    private static func rolloverIfNeeded() {
        let d = UserDefaults.standard
        if d.string(forKey: dateKey) != today {
            d.set(today, forKey: dateKey)
            d.set(0, forKey: countKey)
        }
    }

    static func record(tokens: Int) {
        guard tokens > 0 else { return }
        rolloverIfNeeded()
        let d = UserDefaults.standard
        d.set(d.integer(forKey: countKey) + tokens, forKey: countKey)
    }

    static func estimateTokens(for text: String) -> Int {
        max(1, text.count / 4)
    }

    static func usedToday() -> Int {
        rolloverIfNeeded()
        return UserDefaults.standard.integer(forKey: countKey)
    }

    static func remainingToday() -> Int {
        max(0, dailyCap - usedToday())
    }

    static func ratioToday() -> Double {
        min(1.0, Double(usedToday()) / Double(dailyCap))
    }

    static func formatted(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.2fM", Double(n) / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }
}
