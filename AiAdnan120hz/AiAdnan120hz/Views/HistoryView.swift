import SwiftUI
import SwiftData

// MARK: - Layar history: kartu conversation seperti foto referensi.
// Tiap kartu = satu conversation. Thumbnail dari gambar pertama di chat itu,
// atau gradient placeholder kalau belum ada gambar. Long press = Delete.

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject var appState: AppState
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var showSettings = false
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var confirmDelete: Conversation?

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
                // Hamburger kanan atas → settings.
                HStack {
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Color(.systemGray6)))
                    }
                    .accessibilityLabel("Pengaturan")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if showSearch {
                    TextField("Cari obrolan…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                }

                if filtered.isEmpty {
                    // Empty state.
                    Spacer()
                    VStack(spacing: 12) {
                        Image("SiriOrb")
                            .resizable().scaledToFill()
                            .frame(width: 110, height: 110)
                            .clipShape(Circle())
                            .opacity(0.5)
                        Text("No Conversations")
                            .font(.headline)
                        Text("Ketuk tombol tulis di kanan bawah untuk mulai obrolan baru.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 48)
                    }
                    Spacer()
                } else {
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

                Spacer(minLength: 0)

                // Bottom bar: search kiri, compose kanan.
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

                    Button { onNewChat() } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 60, height: 60)
                            .background(Circle().fill(Color.primary))
                    }
                    .accessibilityLabel("Obrolan baru")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
        .sheet(isPresented: $showSettings) {
            SiriSettingsView()
        }
        .confirmationDialog("Hapus obrolan ini?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = confirmDelete {
                    context.delete(c)
                    try? context.save()
                }
                confirmDelete = nil
            }
            Button("Batal", role: .cancel) { confirmDelete = nil }
        }
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
