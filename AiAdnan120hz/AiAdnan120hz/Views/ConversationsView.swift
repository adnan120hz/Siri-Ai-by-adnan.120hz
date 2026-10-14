import SwiftUI
import SwiftData

// Requires iOS 17+

// MARK: - Conversations (history). Reference: Siri iOS 27.
// Settings gear top-left, "Conversations" title, hamburger top-right
// (Grid / List / Select). Grid cards 2-col rounded-28, list with
// Today / Previous 30 Days sections, select mode with gray checkboxes
// and centered delete alert. Search + compose at the bottom.

enum ConversationsMode {
    case grid, list, select
}

struct ConversationsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    var onSelect: (Conversation) -> Void
    var onNewChat: () -> Void

    @State private var mode: ConversationsMode = .grid
    @State private var selection = Set<UUID>()
    @State private var showSettings = false
    @State private var showDeleteAlert = false
    @State private var pendingDelete: [Conversation] = []
    @State private var searchText = ""
    @State private var showSearch = false

    private var filtered: [Conversation] {
        guard !searchText.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var todayItems: [Conversation] {
        filtered.filter { Calendar.current.isDateInToday($0.updatedAt) }
    }

    private var previousItems: [Conversation] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return filtered.filter {
            !Calendar.current.isDateInToday($0.updatedAt) && $0.updatedAt > cutoff
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: settings left, title center, hamburger/checkmark right.
            HStack {
                SiriCircleButton(systemImage: "gearshape", imageSize: 22) {
                    showSettings = true
                }
                .accessibilityLabel(Text("Settings"))

                Spacer()

                if mode == .select {
                    SiriCircleButton(systemImage: "checkmark", imageSize: 20) {
                        exitSelectMode()
                    }
                    .accessibilityLabel(Text("Done"))
                } else {
                    Menu {
                        Button { mode = .grid } label: {
                            Label("Grid", systemImage: "square.grid.2x2")
                        }
                        Button { mode = .list } label: {
                            Label("List", systemImage: "list.bullet")
                        }
                        Button {
                            mode = .select
                            selection.removeAll()
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                            .background(Circle().fill(SiriTheme.circleFill))
                    }
                    .accessibilityLabel(Text("View options"))
                }
            }
            .padding(.horizontal, SiriTheme.m)
            .padding(.top, SiriTheme.s)

            Text("Conversations")
                .font(.title2)
                .bold()
                .padding(.top, SiriTheme.s)
                .padding(.bottom, SiriTheme.s)

            // Inline search (no NavigationStack needed).
            if showSearch {
                HStack(spacing: SiriTheme.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search conversations", text: $searchText)
                        .submitLabel(.search)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, SiriTheme.m)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal, SiriTheme.m)
                .padding(.bottom, SiriTheme.s)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Content.
            Group {
                if filtered.isEmpty {
                    emptyState
                } else if mode == .grid || mode == .select {
                    gridContent
                } else {
                    listContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer(minLength: 0)

            // Bottom: search left, trash (select mode) / compose right.
            HStack {
                SiriCircleButton(systemImage: "magnifyingglass", imageSize: 24) {
                    withAnimation(SiriTheme.snappy) { showSearch.toggle() }
                }
                .accessibilityLabel(Text("Search"))
                Spacer()
                if mode == .select {
                    Button {
                        let targets = conversations.filter { selection.contains($0.id) }
                        guard !targets.isEmpty else { return }
                        pendingDelete = targets
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 22))
                            .foregroundStyle(selection.isEmpty ? .secondary : .white)
                            .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                            .background(Circle().fill(selection.isEmpty ? SiriTheme.circleFill : Color.red))
                    }
                    .buttonStyle(.plain)
                    .disabled(selection.isEmpty)
                    .accessibilityLabel(Text("Delete selected"))
                } else {
                    Button {
                        onNewChat()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(Color.black))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("New chat"))
                }
            }
            .padding(.horizontal, SiriTheme.xl)
            .padding(.vertical, SiriTheme.l)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showSettings) { SettingsView() }
        .overlay(deleteAlertOverlay)
        .animation(SiriTheme.snappy, value: showSearch)
    }

    // MARK: - Empty state.

    private var emptyState: some View {
        VStack(spacing: SiriTheme.m) {
            SiriOrbFaint()
            Text("No Conversations")
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Grid.

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)],
                spacing: 14
            ) {
                ForEach(filtered) { convo in
                    ConversationCard(
                        conversation: convo,
                        selectMode: mode == .select,
                        isSelected: selection.contains(convo.id)
                    )
                    .onTapGesture {
                        if mode == .select {
                            toggleSelect(convo)
                        } else {
                            onSelect(convo)
                        }
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            pendingDelete = [convo]
                            showDeleteAlert = true
                        }
                    }
                }
            }
            .padding(.horizontal, SiriTheme.m)
        }
    }

    // MARK: - List.

    private var listContent: some View {
        List {
            if !todayItems.isEmpty {
                Section("Today") {
                    ForEach(todayItems) { convo in
                        ConversationListRow(conversation: convo)
                            .onTapGesture { onSelect(convo) }
                    }
                    .onDelete { deleteConversations(todayItems, at: $0) }
                }
            }
            if !previousItems.isEmpty {
                Section("Previous 30 Days") {
                    ForEach(previousItems) { convo in
                        ConversationListRow(conversation: convo)
                            .onTapGesture { onSelect(convo) }
                    }
                    .onDelete { deleteConversations(previousItems, at: $0) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Delete alert (centered, Cancel black + Delete red).

    @ViewBuilder
    private var deleteAlertOverlay: some View {
        if showDeleteAlert {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { showDeleteAlert = false }
                VStack(spacing: 0) {
                    Text(pendingDelete.count == 1 ? "Delete Chat?" : "Delete Chats?")
                        .font(.headline)
                        .padding(.top, SiriTheme.l)
                        .padding(.bottom, SiriTheme.s)
                    Text("This cannot be undone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, SiriTheme.l)
                    Divider()
                    HStack(spacing: 0) {
                        Button {
                            showDeleteAlert = false
                        } label: {
                            Text("Cancel")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SiriTheme.m)
                        }
                        Divider()
                        Button {
                            for c in pendingDelete { context.delete(c) }
                            try? context.save()
                            pendingDelete = []
                            selection.removeAll()
                            showDeleteAlert = false
                            if mode == .select && filtered.isEmpty { mode = .grid }
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } label: {
                            Text("Delete")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SiriTheme.m)
                        }
                    }
                }
                .frame(width: 270)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                )
            }
            .zIndex(2)
        }
    }

    // MARK: - Helpers.

    private func toggleSelect(_ convo: Conversation) {
        withAnimation(SiriTheme.snappy) {
            if selection.contains(convo.id) { selection.remove(convo.id) }
            else { selection.insert(convo.id) }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func exitSelectMode() {
        withAnimation(SiriTheme.snappy) {
            mode = .grid
            selection.removeAll()
        }
    }

    private func deleteConversations(_ items: [Conversation], at offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }
}

// MARK: - Grid card: rounded-28, date + bold white title over thumbnail.

struct ConversationCard: View {
    let conversation: Conversation
    var selectMode: Bool = false
    var isSelected: Bool = false

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f.string(from: conversation.updatedAt)
    }

    private var firstImage: UIImage? {
        for msg in conversation.messages {
            if let img = msg.images.first, let ui = UIImage(data: img.data) {
                return ui
            }
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Thumbnail or neutral placeholder (no purple-blue gradient).
            if let ui = firstImage {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(.systemGray4)
                    Image("SiriOrb")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 110, height: 110)
                        .clipShape(Circle())
                        .opacity(0.35)
                }
            }

            VStack(alignment: .leading, spacing: SiriTheme.xs) {
                Text(dateText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                    .font(.title3)
                    .bold()
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .padding(SiriTheme.m)

            if selectMode {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 24))
                            .foregroundStyle(isSelected ? Color(.systemGray) : .white)
                            .shadow(color: .black.opacity(0.3), radius: 3)
                            .padding(SiriTheme.s)
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(0.85, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: SiriTheme.cardCorner, style: .continuous))
    }
}

// MARK: - List row: title + snippet left, 56pt thumbnail right.

struct ConversationListRow: View {
    let conversation: Conversation

    private var snippet: String {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
            .last(where: { !$0.text.isEmpty })?.text ?? ""
    }

    private var firstImage: UIImage? {
        for msg in conversation.messages {
            if let img = msg.images.first, let ui = UIImage(data: img.data) {
                return ui
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: SiriTheme.xs) {
                Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let ui = firstImage {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.systemGray5))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image("SiriOrb")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())
                            .opacity(0.5)
                    )
            }
        }
        .padding(.vertical, SiriTheme.xs)
    }
}
