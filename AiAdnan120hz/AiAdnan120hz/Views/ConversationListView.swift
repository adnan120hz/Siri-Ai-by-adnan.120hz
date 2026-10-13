import SwiftUI
import SwiftData

// MARK: - Daftar obrolan: grid kartu 2 kolom.

struct ConversationListView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()
                ScrollView {
                    if conversations.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(.secondary)
                            Text("Belum ada obrolan")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Ketuk + untuk mulai obrolan baru.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(conversations) { convo in
                                NavigationLink(destination: ChatView(conversation: convo)) {
                                    ConversationCard(conversation: convo)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        context.delete(convo)
                                        try? context.save()
                                    } label: {
                                        Label("Hapus", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("ai adnan.120hz")
            .navigationBarTitleDisplayMode(.large)
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
        let convo = Conversation(title: "Obrolan baru", modelId: appState.defaultModelId)
        context.insert(convo)
        try? context.save()
    }
}

// MARK: - Kartu obrolan

struct ConversationCard: View {
    let conversation: Conversation
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.updatedAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(conversation.title)
                .font(.subheadline).bold()
                .lineLimit(2)
                .foregroundStyle(.primary)
            if let preview = lastUserText {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer(minLength: 4)
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private var lastUserText: String? {
        let msgs = conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .filter { $0.role == "user" && !$0.text.isEmpty }
        return msgs.last?.text
    }
}
