import SwiftUI
import SwiftData


// MARK: - App root: active chat + conversations browser (full screen).

struct AppRoot: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var activeId: UUID?
    @State private var showConversations = false
    /// True when the active chat was opened from history (shows chevron <).
    @State private var openedFromHistory = false
    /// Onboarding: tampil sekali saat pertama buka.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    private var activeConversation: Conversation? {
        if let id = activeId {
            return conversations.first(where: { $0.id == id })
        }
        return conversations.first
    }

    var body: some View {
        ZStack {
            Group {
                if !hasSeenOnboarding {
                    OnboardingView {
                        hasSeenOnboarding = true
                    }
                } else if let convo = activeConversation {
                    ChatView(
                        conversation: convo,
                        openedFromHistory: openedFromHistory,
                        showConversations: $showConversations
                    )
                } else {
                    Color(.systemBackground)
                        .ignoresSafeArea()
                        .onAppear { ensureConversation() }
                }
            }
            // Histori geser dari kiri (bukan dari bawah).
            if hasSeenOnboarding && showConversations {
                ConversationsView(
                    onSelect: { convo in
                        activeId = convo.id
                        openedFromHistory = true
                        showConversations = false
                    },
                    onNewChat: {
                        let c = makeConversation()
                        activeId = c.id
                        openedFromHistory = false
                        showConversations = false
                    }
                )
                .transition(.move(edge: .leading))
                .zIndex(1)
            }
        }
        .animation(SiriTheme.liquid, value: showConversations)
        .onAppear { ensureConversation() }
        .onChange(of: conversations.count) { _, _ in ensureConversation() }
    }

    private func ensureConversation() {
        if activeConversation != nil { return }
        if let first = conversations.first {
            activeId = first.id
        } else {
            activeId = makeConversation().id
        }
    }

    @discardableResult
    private func makeConversation() -> Conversation {
        let c = Conversation(
            title: "New chat",
            modelId: appState.resolvedModelId(for: appState.activeProvider)
        )
        context.insert(c)
        try? context.save()
        return c
    }
}
