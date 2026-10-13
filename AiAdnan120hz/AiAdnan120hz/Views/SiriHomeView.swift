import SwiftUI
import SwiftData

// MARK: - Beranda ala Siri app iOS 27: orb besar di tengah, ketuk untuk bicara.

struct SiriHomeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var context
    @State private var showVoice = false
    @State private var conversation: Conversation?

    var body: some View {
        NavigationStack {
            ZStack {
                SiriBackground()
                VStack(spacing: 24) {
                    Spacer()

                    Button { openVoice() } label: {
                        SiriOrbView(size: 220)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bicara dengan AI")

                    VStack(spacing: 8) {
                        Text("Hai, aku Siri Ai")
                            .font(.title2).bold()
                        Text("Ketuk orb untuk bicara, atau mulai obrolan teks.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    Button { openVoice() } label: {
                        Label("Bicara", systemImage: "mic.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 14)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    .padding(.bottom, 32)
                }
                .padding()
            }
            .navigationTitle("Siri Ai")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showVoice) {
                if let c = conversation {
                    VoiceModeView(conversation: c)
                }
            }
        }
    }

    private func openVoice() {
        let c = Conversation(title: "Obrolan baru", modelId: appState.defaultModelId)
        context.insert(c)
        try? context.save()
        conversation = c
        showVoice = true
    }
}
