import Foundation
import SwiftData
import SwiftUI

// MARK: - Percakapan

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var modelId: String
    var summary: String
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage] = []
    @Relationship(deleteRule: .cascade, inverse: \SourceAttachment.conversation)
    var sources: [SourceAttachment] = []

    init(title: String, modelId: String) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.updatedAt = Date()
        self.modelId = modelId
        self.summary = ""
    }
}

// MARK: - Pesan chat

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var role: String // "user" | "assistant"
    var text: String
    var createdAt: Date
    var note: String?
    var errorText: String?
    var conversation: Conversation?
    @Relationship(deleteRule: .cascade, inverse: \ImageAttachment.message)
    var images: [ImageAttachment] = []

    init(role: String, text: String, note: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.createdAt = Date()
        self.note = note
    }
}

// MARK: - Lampiran gambar (foto / frame video)

@Model
final class ImageAttachment {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var data: Data
    var isVideoFrame: Bool
    var message: ChatMessage?

    init(data: Data, isVideoFrame: Bool = false) {
        self.id = UUID()
        self.data = data
        self.isVideoFrame = isVideoFrame
    }
}

// MARK: - Source yang diimpor (txt/md/pdf)

@Model
final class SourceAttachment {
    @Attribute(.unique) var id: UUID
    var fileName: String
    var extractedText: String
    var createdAt: Date
    var conversation: Conversation?

    init(fileName: String, extractedText: String) {
        self.id = UUID()
        self.fileName = fileName
        self.extractedText = extractedText
        self.createdAt = Date()
    }
}

// MARK: - Fakta ingatan jangka panjang (lokal, bukan cloud)

@Model
final class MemoryFact {
    @Attribute(.unique) var id: UUID
    var fact: String
    var createdAt: Date

    init(fact: String) {
        self.id = UUID()
        self.fact = fact
        self.createdAt = Date()
    }
}

// MARK: - Source web tersimpan (untuk "Source Web": URL → teks referensi AI)

@Model
final class WebSource {
    @Attribute(.unique) var id: UUID
    var url: String
    var title: String
    var extractedText: String
    var createdAt: Date

    init(url: String, title: String, extractedText: String) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.extractedText = extractedText
        self.createdAt = Date()
    }
}

// MARK: - State global aplikasi

@MainActor
final class AppState: ObservableObject {
    /// Key TANAM via Secrets (di-generate CI dari GitHub Secrets) — tidak ada
    /// lagi input key manual / provider. hasAPIKey = false hanya kalau key
    /// gagal tertanam (CI misconfig).
    @Published var hasAPIKey: Bool = !Secrets.geminiFreeKey.isEmpty

    // @AppStorage tidak memicu objectWillChange di dalam ObservableObject
    // (UI tidak refresh) → pakai @Published + tulis UserDefaults manual.
    @Published var memoryEnabled: Bool = UserDefaults.standard.object(forKey: "memoryEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled") }
    }
    /// "system" | "dark" | "light"
    @Published var appearanceMode: String = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system" {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode") }
    }
    /// Bacakan respons AI dengan suara (AVSpeechSynthesizer).
    @Published var autoSpeak: Bool = UserDefaults.standard.object(forKey: "autoSpeak") as? Bool ?? false {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: "autoSpeak") }
    }

    init() {
        refreshKeyStatus()
    }

    /// Key tertanam = selalu ada (kecuali CI misconfig).
    func refreshKeyStatus() {
        hasAPIKey = !Secrets.geminiFreeKey.isEmpty
    }
}
