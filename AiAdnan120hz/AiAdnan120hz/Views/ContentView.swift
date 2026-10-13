import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.hasAPIKey {
                TabView {
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
    }

    private var colorScheme: ColorScheme? {
        switch appState.appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
