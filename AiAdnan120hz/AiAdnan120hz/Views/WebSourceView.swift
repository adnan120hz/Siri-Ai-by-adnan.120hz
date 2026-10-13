import SwiftUI
import SwiftData

// MARK: - "Source Web": input URL → fetch konten → simpan → lampirkan ke obrolan.
// AI memakai teksnya sebagai referensi (alur sama seperti SourceAttachment).

struct WebSourceView: View {
    @Bindable var conversation: Conversation
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WebSource.createdAt, order: .reverse) private var saved: [WebSource]

    @State private var urlInput = ""
    @State private var isFetching = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("https://github.com/…", text: $urlInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button(isFetching ? "Mengambil…" : "Ambil & Simpan") {
                        Task { @MainActor in await fetchAndSave() }
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .green)
                    }
                } header: {
                    Text("Tambah dari URL")
                } footer: {
                    Text("Contoh: repo GitHub, dokumentasi, artikel. Konten halaman diambil sebagai teks untuk referensi AI.")
                }

                Section {
                    if saved.isEmpty {
                        Text("Belum ada source web tersimpan.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(saved) { ws in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ws.title.isEmpty ? ws.url : ws.title)
                                    .font(.subheadline).lineLimit(2)
                                Text(ws.url)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("\(ws.extractedText.count) karakter · \(ws.createdAt, style: .date)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    context.delete(ws)
                                    try? context.save()
                                } label: {
                                    Label("Hapus", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    attach(ws)
                                } label: {
                                    Label("Lampirkan", systemImage: "paperclip")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                } header: {
                    Text("Tersimpan (\(saved.count))")
                } footer: {
                    Text("Geser kanan untuk melampirkan ke obrolan ini, geser kiri untuk menghapus.")
                }
            }
            .navigationTitle("Source Web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
        }
    }

    private func fetchAndSave() async {
        let input = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        await MainActor.run {
            isFetching = true
            message = nil
            isError = false
        }
        do {
            let (title, text) = try await SourceExtractor.fetchWebText(from: input)
            await MainActor.run {
                let ws = WebSource(url: input, title: title, extractedText: text)
                context.insert(ws)
                try? context.save()
                urlInput = ""
                message = "Tersimpan: \(title) (\(text.count) karakter)."
                isFetching = false
            }
        } catch {
            await MainActor.run {
                message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isError = true
                isFetching = false
            }
        }
    }

    private func attach(_ ws: WebSource) {
        // Hindari duplikat URL yang sama di obrolan ini.
        let exists = conversation.sources.contains { $0.fileName == "🌐 \(ws.url)" }
        if !exists {
            let src = SourceAttachment(fileName: "🌐 \(ws.url)", extractedText: ws.extractedText)
            conversation.sources.append(src)
            try? context.save()
        }
        dismiss()
    }
}
