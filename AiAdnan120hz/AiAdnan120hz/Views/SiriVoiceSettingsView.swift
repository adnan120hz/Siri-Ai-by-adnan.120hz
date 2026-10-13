import SwiftUI

// MARK: - Layar kustomisasi suara ala Siri iOS 27.
// Voice dots / Pace / Expressivity semuanya FUNGSIONAL (dipakai TTS beneran).

struct SiriVoiceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechService()

    private let accents = ["id-ID", "en-US", "en-GB", "en-AU"]
    private let dotColors: [Color] = [.siriVoiceGreen, .siriVoiceYellow, .siriVoiceOrange, .siriVoiceRed, .siriVoicePurple]

    var body: some View {
        ZStack {
            SiriBackground()
            ScrollView {
                VStack(spacing: 18) {
                    SiriOrbView(size: 150)
                        .frame(height: 200)
                        .padding(.top, 8)

                    // Voice row: label kiri, dropdown kanan
                    HStack {
                        Text("Voice")
                            .font(.title3)
                            .foregroundStyle(.primary)
                        Spacer()
                        Menu {
                            ForEach(accents, id: \.self) { a in
                                Button(a) { speech.accent = a }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(shortAccent)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.25))
                            .clipShape(Capsule())
                        }
                    }

                    // Voice dots (5 warna)
                    HStack(spacing: 28) {
                        ForEach(0..<5) { i in
                            Button { speech.voiceIndex = i } label: {
                                ZStack {
                                    Circle()
                                        .fill(dotColors[i])
                                        .frame(width: 44, height: 44)
                                    if speech.voiceIndex == i {
                                        Circle()
                                            .strokeBorder(Color.siriVoiceGreen, lineWidth: 3)
                                            .frame(width: 54, height: 54)
                                        Text("\(i + 1)")
                                            .font(.headline).bold()
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    // Pace
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pace").font(.title3)
                        SiriSlider(value: $speech.pace)
                    }

                    // Expressivity
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Expressivity").font(.title3)
                        SiriSlider(value: $speech.expressivity)
                    }

                    // Judul + subtitle
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Customize Your Siri Voice")
                            .font(.title).bold()
                        Text("You'll hear this voice in Siri, Maps, and Safari.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)

                    Button {
                        speech.saveVoicePrefs()
                        dismiss()
                    } label: {
                        Text("Continue")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.blue)
                            .clipShape(Capsule())
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var shortAccent: String {
        switch speech.accent {
        case "id-ID": return "Indonesian"
        case "en-US": return "American"
        case "en-GB": return "British"
        case "en-AU": return "Australian"
        default: return speech.accent
        }
    }
}

// MARK: - Slider ala Siri: track hijau, thumb putih

struct SiriSlider: View {
    @Binding var value: Double // 0...1

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 8)
                Capsule()
                    .fill(Color.siriVoiceGreen)
                    .frame(width: w * value, height: 8)
                Circle()
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                    .shadow(radius: 3)
                    .offset(x: w * value - 14)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = min(1, max(0, g.location.x / w))
                    }
            )
        }
        .frame(height: 28)
    }
}

// MARK: - Background gelap/terang adaptif

struct SiriBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (scheme == .dark ? Color.black : Color(UIColor.systemBackground))
            .ignoresSafeArea()
    }
}
