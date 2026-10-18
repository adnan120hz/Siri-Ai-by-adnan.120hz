import SwiftUI


// MARK: - Content gate: AI key tertanam (Secrets) sebelum chatting.

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
            Text("AI key is not embedded in this build.\nRebuild from CI with the correct GitHub Secrets.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showSettings = true
            } label: {
                Text("Open Settings")
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
