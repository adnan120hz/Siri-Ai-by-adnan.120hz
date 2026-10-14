import SwiftUI

// Requires iOS 17+

// MARK: - Content gate: API key required before chatting.

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        Group {
            if appState.hasAPIKey {
                AppRoot()
            } else {
                setupGate
            }
        }
        .preferredColorScheme(colorScheme)
        .onAppear { Task { @MainActor in appState.refreshKeyStatus() } }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var setupGate: some View {
        VStack(spacing: SiriTheme.l) {
            Spacer()
            SiriOrbFaint()
            Text("Siri Ai")
                .font(.title)
                .bold()
            Text("Add an API key to start chatting.\nYour key stays on this phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showSettings = true
            } label: {
                Text("Set up API Key")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, SiriTheme.xl)
                    .padding(.vertical, SiriTheme.m)
                    .background(Capsule().fill(Color.black))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(SiriTheme.xl)
        .background(Color(.systemBackground))
    }

    private var colorScheme: ColorScheme? {
        switch appState.appearanceMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
