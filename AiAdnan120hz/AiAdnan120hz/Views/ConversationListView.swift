import SwiftUI
import SwiftData

struct ConversationListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @State private var activeConversation: Conversation?

    var body: some View {
        NavigationStack {
            Group {
                if conversations.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("Belum ada obrolan")
                            .font(.headline)
                        Text("Ketuk + untuk mulai obrolan baru dengan AI dari apinex.bond.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                } else {
                    List {
                        ForEach(conversations) { convo in
                            NavigationLink(destination: ChatView(conversation: convo)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(convo.title).font(.headline).lineLimit(1)
                                    HStack {
                                        Text(convo.modelId.isEmpty ? "model bawaan" : convo.modelId)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Spacer()
                                        Text(convo.updatedAt, style: .relative)
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Ai Adnan.120hz")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { newConversation() } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func newConversation() {
        let model = appState.defaultModelId
        let convo = Conversation(title: "Obrolan baru", modelId: model)
        context.insert(convo)
        try? context.save()
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(conversations[i]) }
        try? context.save()
    }
}
