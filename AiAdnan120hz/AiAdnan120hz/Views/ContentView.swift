import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("didCompleteVoiceSetup") private var didCompleteVoiceSetup = false
    @State private var showVoiceSetup = false

    var body: some View {
        Group {
            if appState.hasAPIKey {
                TabView {
                    SiriHomeView()
                        .tabItem { Label("Beranda", systemImage: "sparkles") }
                    ConversationListView()
                        .tabItem { Label("Obrolan", systemImage: "bubble.left.and.bubble.right") }
                    SettingsView()
                        .tabItem { Label("Pengaturan", systemImage: "gearshape") }
                }
            } else {
                APIKeyView()
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear { Task { @MainActor in appState.refreshKeyStatus() } }
        .onChange(of: appState.hasAPIKey) { _, has in
            // Alur setup ala Siri iOS 27: begitu API key dipasang pertama kali,
            // tampilkan layar kustomisasi suara sekali saja.
            if has && !didCompleteVoiceSetup {
                showVoiceSetup = true
            }
        }
        .fullScreenCover(isPresented: $showVoiceSetup) {
            NavigationStack { SiriVoiceSettingsView() }
                .preferredColorScheme(colorScheme)
                .onDisappear { didCompleteVoiceSetup = true }
        }
    }

    private var colorScheme: ColorScheme? {
        switch appState.appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
