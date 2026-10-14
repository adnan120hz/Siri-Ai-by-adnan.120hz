import SwiftUI
import SwiftData

// MARK: - Layar history: Grid / List / Select (persis Siri asli).
// Hamburger kanan atas → pilih mode tampilan.
// Grid: kartu 2 kolom. List: baris + thumbnail kanan. Select: checkbox + trash.

enum HistoryViewMode: String, CaseIterable {
    case grid, list, select

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        case .select: return "Select"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .select: return "checkmark.circle"
        }
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var showSettings = false
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var confirmDelete: Conversation?
    @State private var viewMode: HistoryViewMode = .grid
    @State private var selectedIds: Set<UUID> = []
    @State private var showDeleteSelected = false

    var onSelect: (Conversation) -> Void
    var onNewChat: () -> Void

    private var filtered: [Conversation] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(q)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Kanan atas: hamburger (Grid/List/Select) — select mode jadi tombol ✓ done.
                HStack {
                    Spacer()
                    if viewMode == .select {
                        // Select mode: hamburger diganti ✓ untuk keluar (persis Siri asli).
                        Button {
                            viewMode = .grid
                            selectedIds.removeAll()
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(Color(.systemGray6)))
                        }
                        .accessibilityLabel("Selesai memilih")
                    } else {
                        Menu {
                            ForEach(HistoryViewMode.allCases, id: \.self) { mode in
                                Button {
                                    viewMode = mode
                                    if mode != .select { selectedIds.removeAll() }
                                } label: {
                                    Label(mode.title, systemImage: mode.icon)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 52, height: 52)
                                .background(Circle().fill(Color(.systemGray6)))
                        }
                        .accessibilityLabel("Opsi tampilan")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                // Judul "Conversations" bold tengah (persis Siri asli).
                Text("Conversations")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)

                if showSearch {
                    TextField("Cari obrolan…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                if filtered.isEmpty && searchText.isEmpty {
                    // Empty state persis video: orb faint + "No Conversations" bold.
                    Spacer()
                    VStack(spacing: 16) {
                        Image("SiriOrb")
                            .resizable().scaledToFill()
                            .frame(width: 110, height: 110)
                            .clipShape(Circle())
                            .opacity(0.25)
                        Text("No Conversations")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                } else if filtered.isEmpty {
                    // Hasil pencarian kosong.
                    Spacer()
                    Text("Tidak ada hasil.")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    switch viewMode {
                    case .grid:
                        gridView
                    case .list:
                        listView
                    case .select:
                        selectView
                    }
                }

                Spacer(minLength: 0)

                // Bottom bar: search kiri, compose kanan.
                // Mode Select: tombol trash kanan bawah ganti compose.
                HStack {
                    Button {
                        withAnimation { showSearch.toggle() }
                        if !showSearch { searchText = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color(.systemGray6)))
                    }
                    .accessibilityLabel("Cari")

                    Spacer()

                    if viewMode == .select {
                        Button {
                            if !selectedIds.isEmpty { showDeleteSelected = true }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 60, height: 60)
                                .background(Circle().fill(selectedIds.isEmpty ? Color.gray : Color.red))
                        }
                        .accessibilityLabel("Hapus yang dipilih")
                        .disabled(selectedIds.isEmpty)
                    } else {
                        Button { onNewChat() } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color(.systemBackground))
                                .frame(width: 60, height: 60)
                                .background(Circle().fill(Color.primary))
                        }
                        .accessibilityLabel("Obrolan baru")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            // Alert delete custom di tengah layar.
            deleteAlertOverlay
        }
        .sheet(isPresented: $showSettings) {
            SiriSettingsView()
        }
    }

    // MARK: - Alert delete di tengah layar (persis Siri asli):
    // 2 tombol horizontal: Cancel (hitam) + Delete (merah).

    private var deleteAlertOverlay: some View {
        Group {
            if confirmDelete != nil || showDeleteSelected {
                let isMulti = showDeleteSelected
                let title = isMulti ? "Delete Chats" : "Hapus obrolan ini?"
                let message = isMulti
                    ? "Hapus \(selectedIds.count) obrolan yang dipilih? Tindakan ini tidak bisa dibatalkan."
                    : (confirmDelete?.title ?? "")
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        confirmDelete = nil
                        showDeleteSelected = false
                    }
                VStack(spacing: 0) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 20)
                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 6)
                    }
                    Divider()
                        .padding(.top, 16)
                    HStack(spacing: 0) {
                        Button {
                            confirmDelete = nil
                            showDeleteSelected = false
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 17))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        Divider()
                        Button {
                            if isMulti {
                                deleteSelected()
                            } else if let c = confirmDelete {
                                context.delete(c)
                                try? context.save()
                            }
                            confirmDelete = nil
                            showDeleteSelected = false
                        } label: {
                            Text("Delete")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.systemBackground))
                )
                .padding(.horizontal, 52)
            }
        }
    }

    // MARK: - Grid

    private var gridView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(filtered) { convo in
                    ConversationCard(conversation: convo) {
                        onSelect(convo)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            confirmDelete = convo
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - List

    private var listView: some View {
        List {
            Section {
                ForEach(filtered) { convo in
                    ConversationRow(conversation: convo) {
                        onSelect(convo)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            context.delete(convo)
                            try? context.save()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                // Section header persis Siri asli.
                Text("Previous 30 Days")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Select

    private var selectView: some View {
        List {
            ForEach(filtered) { convo in
                HStack(spacing: 12) {
                    Image(systemName: selectedIds.contains(convo.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(selectedIds.contains(convo.id) ? Color.gray : Color.secondary)
                    ConversationRow(conversation: convo) {}
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedIds.contains(convo.id) {
                        selectedIds.remove(convo.id)
                    } else {
                        selectedIds.insert(convo.id)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func deleteSelected() {
        for convo in filtered where selectedIds.contains(convo.id) {
            context.delete(convo)
        }
        try? context.save()
        selectedIds.removeAll()
        showDeleteSelected = false
    }
}

// MARK: - Kartu conversation: rounded besar, tanggal M/D/YY + judul bold putih di atas foto.

struct ConversationCard: View {
    @Bindable var conversation: Conversation
    var onTap: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()

    /// Gambar pertama dari pesan user mana pun di conversation ini.
    private var thumbnailData: Data? {
        conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .flatMap { $0.images }
            .first?.data
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                if let data = thumbnailData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(height: 190)
                        .clipped()
                } else {
                    // Placeholder gradient kalau belum ada gambar.
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .frame(height: 190)
                    .overlay(
                        Image("SiriOrb")
                            .resizable().scaledToFill()
                            .frame(width: 90, height: 90)
                            .clipShape(Circle())
                            .opacity(0.6)
                    )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dateFmt.string(from: conversation.updatedAt))
                        .font(.system(size: 15, weight: .semibold))
                    Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .padding(14)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 28))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Baris list: thumbnail kecil kanan, judul + snippet kiri.

struct ConversationRow: View {
    @Bindable var conversation: Conversation
    var onTap: () -> Void

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        return f
    }()

    private var thumbnailData: Data? {
        conversation.messages
            .sorted { $0.createdAt < $1.createdAt }
            .flatMap { $0.images }
            .first?.data
    }

    private var snippet: String {
        let last = conversation.messages.sorted { $0.createdAt < $1.createdAt }.last
        let t = last?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "New Chat" : String(t.prefix(80))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title.isEmpty ? "New Chat" : conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(Self.dateFmt.string(from: conversation.updatedAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let data = thumbnailData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image("SiriOrb")
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        .opacity(0.7)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
