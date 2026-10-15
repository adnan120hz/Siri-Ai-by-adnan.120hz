import SwiftUI
import SwiftData


// MARK: - Conversations (photo history). Reference: Siri iOS 27.
// Masonry 2-column photo grid with REAL photos full-bleed (no gray placeholders),
// date + bold white title overlaid at top. Settings gear top-left,
// hamburger top-right (Grid / List / Select). Search + compose at bottom.
// Staggered spring entrance, long-press to delete.

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
    @State private var renameTarget: Conversation?
    @State private var renameText = ""

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
            // Top bar: hamburger kanan (berisi Grid / List / Select / Settings).
            HStack {
                Spacer()

                if mode == .select {
                    SiriCircleButton(systemImage: "checkmark", imageSize: 20) {
                        exitSelectMode()
                    }
                    .accessibilityLabel(Text("Done"))
                } else {
                    Menu {
                        Button { withAnimation(SiriTheme.liquid) { mode = .grid } } label: {
                            Label("Grid", systemImage: "square.grid.2x2")
                        }
                        Button { withAnimation(SiriTheme.liquid) { mode = .list } } label: {
                            Label("List", systemImage: "list.bullet")
                        }
                        Button {
                            withAnimation(SiriTheme.liquid) {
                                mode = .select
                                selection.removeAll()
                            }
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(.white)
                                    .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
                            )
                    }
                    .tint(.primary)
                    .accessibilityLabel(Text("View options"))
                }
            }
            .padding(.horizontal, SiriTheme.m)
            .padding(.top, SiriTheme.s)

            // Title only in list mode (photo view has none, per reference).
            if mode == .list {
                Text("Conversations")
                    .font(.title2)
                    .bold()
                    .padding(.top, SiriTheme.s)
                    .padding(.bottom, SiriTheme.s)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // Inline search.
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
                } else if mode == .select {
                    selectListContent
                } else if mode == .list {
                    listContent
                } else {
                    masonryContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Spacer(minLength: 0)

            // Bottom: search left, trash (select) / compose right.
            HStack {
                SiriCircleButton(systemImage: "magnifyingglass", imageSize: 24) {
                    withAnimation(SiriTheme.liquid) { showSearch.toggle() }
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
                            .foregroundStyle(selection.isEmpty ? Color.secondary : Color.white)
                            .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                            .background(
                                selection.isEmpty ? AnyView(SiriCircleGlassFill()) : AnyView(Circle().fill(Color.red))
                            )
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
                            .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                            .background(Circle().fill(Color.black))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("New chat"))
                }
            }
            .padding(.horizontal, SiriTheme.xl)
            .padding(.vertical, SiriTheme.l)
            .background(Color.clear)
        }
        .background(Color(.systemBackground))
        .onAppear {
            // Keyboard auto-tutup saat masuk menu histori.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .overlay(deleteAlertOverlay)
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Nama baru", text: $renameText)
            Button("Batal", role: .cancel) { renameTarget = nil }
            Button("Simpan") {
                if let target = renameTarget {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        target.title = trimmed
                        try? context.save()
                    }
                }
                renameTarget = nil
            }
        }
        .animation(SiriTheme.liquid, value: showSearch)
        .animation(SiriTheme.liquid, value: mode)
    }

    // MARK: - Empty state.

    private var emptyState: some View {
        VStack(spacing: SiriTheme.m) {
            SiriOrbFaint(animate: true)
            Text("No Conversations")
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Masonry photo grid (primary view).

    private var masonryContent: some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - 40 - 14) / 2
            ScrollView {
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        ForEach(masonryColumn(0)) { convo in
                            let idx = filtered.firstIndex(where: { $0.id == convo.id }) ?? 0
                            MasonryCard(
                                conversation: convo,
                                index: idx,
                                columnWidth: colWidth,
                                selectMode: mode == .select,
                                isSelected: selection.contains(convo.id),
                                onTap: {
                                    if mode == .select { toggleSelect(convo) }
                                    else { onSelect(convo) }
                                },
                                onDelete: {
                                    pendingDelete = [convo]
                                    showDeleteAlert = true
                                },
                                onRename: {
                                    renameTarget = convo
                                    renameText = convo.title
                                }
                            )
                        }
                    }
                    VStack(spacing: 14) {
                        ForEach(masonryColumn(1)) { convo in
                            let idx = filtered.firstIndex(where: { $0.id == convo.id }) ?? 0
                            MasonryCard(
                                conversation: convo,
                                index: idx,
                                columnWidth: colWidth,
                                selectMode: mode == .select,
                                isSelected: selection.contains(convo.id),
                                onTap: {
                                    if mode == .select { toggleSelect(convo) }
                                    else { onSelect(convo) }
                                },
                                onDelete: {
                                    pendingDelete = [convo]
                                    showDeleteAlert = true
                                },
                                onRename: {
                                    renameTarget = convo
                                    renameText = convo.title
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, SiriTheme.s)
            }
        }
    }

    /// Split filtered conversations into two masonry columns (alternating).
    private func masonryColumn(_ col: Int) -> [Conversation] {
        filtered.enumerated().compactMap { $0.offset % 2 == col ? $0.element : nil }
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

    // MARK: - Select mode list (checkmark + title + preview + thumbnail).

    private var selectListContent: some View {
        List {
            if !todayItems.isEmpty {
                Section("Today") {
                    ForEach(todayItems) { convo in
                        SelectListRow(conversation: convo,
                                      isSelected: selection.contains(convo.id),
                                      onToggle: { toggleSelect(convo) })
                    }
                }
            }
            if !previousItems.isEmpty {
                Section("Previous 30 Days") {
                    ForEach(previousItems) { convo in
                        SelectListRow(conversation: convo,
                                      isSelected: selection.contains(convo.id),
                                      onToggle: { toggleSelect(convo) })
                    }
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        withAnimation(SiriTheme.pop) { showDeleteAlert = false }
                    }
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
                            withAnimation(SiriTheme.pop) { showDeleteAlert = false }
                        } label: {
                            Text("Cancel")
                                .font(.body)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SiriTheme.m)
                        }
                        .buttonStyle(.plain)
                        .tint(.primary)
                        Divider()
                        Button {
                            for c in pendingDelete { context.delete(c) }
                            try? context.save()
                            pendingDelete = []
                            selection.removeAll()
                            withAnimation(SiriTheme.pop) { showDeleteAlert = false }
                            if mode == .select && filtered.isEmpty {
                                withAnimation(SiriTheme.liquid) { mode = .grid }
                            }
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        } label: {
                            Text("Delete")
                                .font(.body)
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, SiriTheme.m)
                        }
                        .buttonStyle(.plain)
                        .tint(.red)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 270)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .white.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                    }
                )
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(2)
        }
    }

    // MARK: - Helpers.

    private func toggleSelect(_ convo: Conversation) {
        withAnimation(SiriTheme.liquid) {
            if selection.contains(convo.id) { selection.remove(convo.id) }
            else { selection.insert(convo.id) }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func exitSelectMode() {
        withAnimation(SiriTheme.liquid) {
            mode = .grid
            selection.removeAll()
        }
    }

    private func deleteConversations(_ items: [Conversation], at offsets: IndexSet) {
        for i in offsets { context.delete(items[i]) }
        try? context.save()
    }
}

// MARK: - Masonry card: REAL photo full-bleed, date + title overlaid at top.
// Height follows the real photo aspect ratio (natural masonry rhythm).
// Staggered spring entrance: 0.05s delay per index.

struct MasonryCard: View {
    let conversation: Conversation
    let index: Int
    let columnWidth: CGFloat
    var selectMode: Bool = false
    var isSelected: Bool = false
    var onTap: () -> Void
    var onDelete: () -> Void
    var onRename: () -> Void = {}

    @State private var appeared = false
    // Cache: decode UIImage sekali di onAppear, bukan tiap body evaluate (berat di main thread).
    @State private var cachedPhoto: UIImage?

    private func loadPhoto() {
        for msg in conversation.messages {
            if let img = msg.images.first, let ui = UIImage(data: img.data) {
                cachedPhoto = ui
                return
            }
        }
        cachedPhoto = nil
    }

    /// Card aspect (h/w): real photo ratio clamped, else varied rhythm.
    private var aspect: CGFloat {
        if let ui = cachedPhoto, ui.size.width > 0 {
            return min(1.6, max(0.75, ui.size.height / ui.size.width))
        }
        return [1.05, 1.3, 0.9][index % 3]
    }

    private var dateText: String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f.string(from: conversation.updatedAt)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let ui = cachedPhoto {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Placeholder: subtle gradient + SMALL orb centered.
                    // Jangan zoom — orb kecil di tengah, tidak memenuhi kartu.
                    ZStack {
                        LinearGradient(
                            colors: [Color(.systemGray6), Color(.systemGray5)],
                            startPoint: .top, endPoint: .bottom
                        )
                        Image("SiriOrb")
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                            .opacity(0.6)
                    }
                }
            }
            .frame(width: columnWidth, height: columnWidth * aspect)
            .clipped()

            // Date + title overlaid at top, readable over any photo.
            VStack(alignment: .leading, spacing: 4) {
                Text(dateText)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                    .font(.title2)
                    .bold()
                    .lineLimit(2)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 5, y: 1)
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
        .frame(width: columnWidth, height: columnWidth * aspect)
        .clipShape(RoundedRectangle(cornerRadius: SiriTheme.cardCorner, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .onTapGesture(perform: onTap)
        .contextMenu {
            Button("Rename") { onRename() }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .onAppear { loadPhoto() }
        .onChange(of: conversation.messages.count) { _, _ in loadPhoto() }
        .task {
            // Staggered entrance: 0.05s per index, spring.
            try? await Task.sleep(nanoseconds: UInt64(min(index, 12)) * 50_000_000)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                appeared = true
            }
        }
    }
}

// MARK: - List row: title + snippet left, 56pt thumbnail right.

struct ConversationListRow: View {
    let conversation: Conversation

    // Cache: decode UIImage sekali, bukan tiap body evaluate.
    @State private var cachedThumb: UIImage?

    private func loadThumb() {
        for msg in conversation.messages {
            if let img = msg.images.first, let ui = UIImage(data: img.data) {
                cachedThumb = ui
                return
            }
        }
        cachedThumb = nil
    }

    private var snippet: String {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
            .last(where: { !$0.text.isEmpty })?.text ?? ""
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
            if let ui = cachedThumb {
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
        .onAppear { loadThumb() }
        .onChange(of: conversation.messages.count) { _, _ in loadThumb() }
    }
}

// MARK: - Select mode row: checkmark + title + preview + thumbnail.

struct SelectListRow: View {
    let conversation: Conversation
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var cachedThumb: UIImage?

    private func loadThumb() {
        for msg in conversation.messages {
            if let img = msg.images.first, let ui = UIImage(data: img.data) {
                cachedThumb = ui
                return
            }
        }
        cachedThumb = nil
    }

    private var snippet: String {
        conversation.messages.sorted { $0.createdAt < $1.createdAt }
            .last(where: { !$0.text.isEmpty })?.text ?? ""
    }

    var body: some View {
        HStack(spacing: 12) {
            // Blue checkmark circle.
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24))
                .foregroundStyle(isSelected ? Color.blue : Color(.systemGray3))
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title.isEmpty ? "New chat" : conversation.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let ui = cachedThumb {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onAppear { loadThumb() }
    }
}
