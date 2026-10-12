import Foundation

// MARK: - Kuota penyimpanan lokal: cap 25 GB, peringatan di 90%.

enum StorageQuota {
    static let capBytes: Int64 = 25 * 1024 * 1024 * 1024
    static var warnThreshold: Double { 0.9 }

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

    static var usageRatio: Double {
        let used = Double(usedBytes())
        guard capBytes > 0 else { return 0 }
        return used / Double(capBytes)
    }

    static var isOverWarning: Bool { usageRatio >= warnThreshold }
}
