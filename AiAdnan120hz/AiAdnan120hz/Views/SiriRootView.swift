import SwiftUI
import SwiftData

// MARK: - Root: layar utama Siri + layar history (full screen).

struct SiriRootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var activeId: UUID?
    @State private var showHistory = false

    private var activeConversation: Conversation? {
        if let id = activeId {
            return conversations.first(where: { $0.id == id })
        }
        return conversations.first
    }

    var body: some View {
        Group {
            if let convo = activeConversation {
                SiriHomeView(conversation: convo, showHistory: $showHistory)
            } else {
                // Belum ada conversation: buat satu.
                Color(.systemBackground).ignoresSafeArea()
                    .onAppear { ensureConversation() }
            }
        }
        .fullScreenCover(isPresented: $showHistory) {
            HistoryView(
                onSelect: { convo in
                    activeId = convo.id
                    showHistory = false
                },
                onNewChat: {
                    let c = makeConversation()
                    activeId = c.id
                    showHistory = false
                }
            )
        }
        .onAppear { ensureConversation() }
        .onChange(of: conversations.count) { _, _ in ensureConversation() }
    }

    private func ensureConversation() {
        if activeConversation != nil { return }
        if let first = conversations.first {
            activeId = first.id
        } else {
            let c = makeConversation()
            activeId = c.id
        }
    }

    @discardableResult
    private func makeConversation() -> Conversation {
        let provider = appState.activeProvider
        var modelId = appState.defaultModelId
        if !provider.allowsModel(modelId) || modelId.isEmpty {
            modelId = provider.defaultModel
        }
        let c = Conversation(title: "Obrolan baru", modelId: modelId)
        context.insert(c)
        try? context.save()
        return c
    }
}
