import Foundation
import Security

// MARK: - Penyedia AI: APInex dan NVIDIA NIM. Key disimpan terpisah per provider.

enum AIProvider: String, CaseIterable, Identifiable {
    case apinex
    case nvidia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apinex: return "APInex"
        case .nvidia: return "NVIDIA NIM"
        }
    }

    var baseURL: URL {
        switch self {
        case .apinex: return URL(string: "https://api.apinex.bond/v1")!
        case .nvidia: return URL(string: "https://integrate.api.nvidia.com/v1")!
        }
    }

    /// Model bawaan tiap provider.
    var defaultModel: String {
        switch self {
        case .apinex: return "free/glm-5.3-flash"
        case .nvidia: return "z-ai/glm-5-3-flash"
        }
    }

    /// Model fallback kalau /models gagal/kosong.
    var modelFallback: [String] {
        switch self {
        case .apinex: return AIClient.freeModelFallback
        case .nvidia: return ["z-ai/glm-5-3-flash"]
        }
    }

    /// Aturan model yang boleh dipakai. APInex: hanya model free (prefix "free/").
    /// NVIDIA NIM: semua model yang dikembalikan /models boleh dipakai.
    func allowsModel(_ id: String) -> Bool {
        let t = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        switch self {
        case .apinex: return t.lowercased().hasPrefix("free/")
        case .nvidia: return true
        }
    }

    var keyHelp: String {
        switch self {
        case .apinex:
            return "Tempel API key kamu dari apinex.bond."
        case .nvidia:
            return "Tempel API key kamu dari build.nvidia.com (NVIDIA NIM). Gratis, 10rb request/hari."
        }
    }

    var keyDestinationNote: String {
        switch self {
        case .apinex:
            return "Key hanya disimpan di Keychain HP ini — tidak dikirim ke mana pun selain api.apinex.bond saat chat."
        case .nvidia:
            return "Key hanya disimpan di Keychain HP ini — tidak dikirim ke mana pun selain integrate.api.nvidia.com saat chat."
        }
    }

    /// Link untuk mendapatkan API key (ditampilkan dalam Bahasa Inggris sesuai permintaan user).
    var keyGetURL: URL {
        switch self {
        case .apinex: return URL(string: "https://apinex.bond")!
        case .nvidia: return URL(string: "https://build.nvidia.com/settings/api-keys")!
        }
    }

    var keyGetLinkText: String {
        return "Get your API key here"
    }
}

// MARK: - Keychain: satu-satunya tempat API key disimpan.
// Tidak pernah di-hardcode, tidak pernah di-log. Satu account per provider.

enum KeychainStore {
    private static let service = "com.adnan120hz.aiadnan120hz.apikey"

    private static func account(for provider: AIProvider) -> String {
        provider.rawValue
    }

    static func save(_ key: String, for provider: AIProvider) -> Bool {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load(for provider: AIProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return nil }
        return key
    }

    static func remove(for provider: AIProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: provider),
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Kompatibilitas: API lama = provider APInex (account "apinex" sama).

    static func save(_ key: String) -> Bool { save(key, for: .apinex) }
    static func load() -> String? { load(for: .apinex) }
    static func remove() -> Bool { remove(for: .apinex) }

    /// Tampilkan versi tersamar, mis. "sk-•••ab12". Tidak pernah mengembalikan key asli.
    static func masked(_ key: String) -> String {
        let tail = String(key.suffix(4))
        let prefix = key.prefix(3)
        return "\(prefix)-•••\(tail)"
    }
}
