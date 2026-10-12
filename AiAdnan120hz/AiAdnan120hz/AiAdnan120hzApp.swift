import SwiftUI
import SwiftData

@main
struct AiAdnan120hzApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .modelContainer(for: [
            Conversation.self,
            ChatMessage.self,
            ImageAttachment.self,
            SourceAttachment.self,
            MemoryFact.self,
        ])
    }
}
