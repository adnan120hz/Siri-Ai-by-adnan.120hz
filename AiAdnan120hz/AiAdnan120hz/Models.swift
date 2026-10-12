import Foundation
import SwiftData

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

// MARK: - State global aplikasi

@MainActor
final class AppState: ObservableObject {
    @Published var hasAPIKey: Bool = false
    @Published var keyMasked: String = ""
    @Published var availableModels: [String] = []
    @Published var modelsError: String?

    @AppStorage("defaultModelId") var defaultModelId: String = ""
    @AppStorage("memoryEnabled") var memoryEnabled: Bool = true

    func refreshKeyStatus() {
        if let key = KeychainStore.load(), !key.isEmpty {
            hasAPIKey = true
            keyMasked = KeychainStore.masked(key)
        } else {
            hasAPIKey = false
            keyMasked = ""
        }
    }
}
