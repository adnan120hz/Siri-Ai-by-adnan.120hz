import Foundation

// MARK: - Kuota penyimpanan lokal: cap DINAMIS (25 GB free / 50 GB premium),
// peringatan di 90%. Enforcement nyata di titik write eksplisit via
// canAccommodate(_:). SwiftData menyimpan implisit — di sana enforcement
// hanya best-effort (lihat komentar di titik save), tidak diklaim total.

enum StorageQuota {
    /// Cap dinamis mengikuti status premium: 25 GB (free) / 50 GB (premium).
    @MainActor
    static var capBytes: Int64 {
        PremiumState.shared.isPremium ? 50 * 1024 * 1024 * 1024 : 25 * 1024 * 1024 * 1024
    }
    static var warnThreshold: Double { 0.9 }

    /// Pesan blokir storage (verbatim kontrak).
    static let fullMessage = "Storage full (25GB/50GB limit). Delete old data or upgrade to premium."

    /// Proyeksi: True kalau `additionalBytes` masih muat di bawah cap
    /// (usedBytes + additional ≤ cap).
    @MainActor
    static func canAccommodate(_ additionalBytes: Int64) -> Bool {
        usedBytes() + max(0, additionalBytes) <= capBytes
    }

    /// Total byte yang dipakai app di sandbox-nya (dokumen, cache, SwiftData, dsb).
    static func usedBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for dir in [fm.urls(for: .documentDirectory, in: .userDomainMask).first,
                    fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                    fm.urls(for: .cachesDirectory, in: .userDomainMask).first].compactMap({ $0 }) {
            total += size(of: dir)
        }
        return total
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let isDir = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir == true { continue }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.2f GB", gb) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
    }

    @MainActor
    static var usageRatio: Double {
        let used = Double(usedBytes())
        guard capBytes > 0 else { return 0 }
        return used / Double(capBytes)
    }

    @MainActor
    static var isOverWarning: Bool { usageRatio >= warnThreshold }
}
