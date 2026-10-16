import SwiftUI

// MARK: - Voice Model: pilih suara AI (Robot / Cowok / Cewek) + bahasa (English / Indonesia)
// UI ala iOS 27: orb bercahaya di atas, 3 warna, slider pace, dropdown bahasa.

struct VoiceModelView: View {
    @StateObject private var voice = VoiceService()
    @Environment(\.dismiss) private var dismiss

    /// Warna orb untuk tiap model.
    private func color(for model: VoiceModel) -> Color {
        switch model {
        case .robot: return .gray
        case .male: return .blue
        case .female: return .pink
        }
    }

    /// Test suara pakai kalimat sesuai bahasa terpilih.
    private func playSample() {
        let model = voice.voiceModel
        let sample: String
        switch voice.voiceLanguage {
        case .english:
            sample = "Hello, this is the \(model.title) voice."
        case .indonesian:
            sample = "Halo, ini suara \(model.title)."
        }
        voice.speak(sample)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Orb bercahaya — warna berubah sesuai model terpilih.
                VoiceOrbGlow(color: color(for: voice.voiceModel))
                    .frame(height: 280)
                    .padding(.top, 20)

                // Label "Voice" + dropdown bahasa (English / Indonesia).
                HStack {
                    Text("Voice")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Spacer()
                    Menu {
                        ForEach(VoiceLanguage.allCases) { lang in
                            Button {
                                voice.voiceLanguage = lang
                                playSample()
                            } label: {
                                HStack {
                                    Text(lang.title)
                                    if voice.voiceLanguage == lang {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(voice.voiceLanguage.title)
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.85))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .accessibilityLabel(Text("Language"))
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                // 3 warna: robot, cowok, cewek.
                HStack(spacing: 20) {
                    ForEach(VoiceModel.allCases) { model in
                        Button {
                            withAnimation(.spring(response: 0.4)) {
                                voice.voiceModel = model
                            }
                            // Test suara saat dipilih.
                            playSample()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(color(for: model))
                                    .frame(width: 56, height: 56)
                                if voice.voiceModel == model {
                                    Circle()
                                        .stroke(color(for: model), lineWidth: 3)
                                        .frame(width: 68, height: 68)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(model.title))
                    }
                }
                .padding(.top, 20)

                // Slider pace (kecepatan suara).
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pace")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: Binding(
                        get: { Double(voice.speechRate) },
                        set: { voice.speechRate = Float($0) }
                    ), in: 0.5...1.5, step: 0.05)
                    .tint(.white)
                    // Reset speed — kiri bawah.
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            voice.speechRate = 1.0
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Reset Speed")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityLabel(Text("Reset speed"))
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                // Slider expressivity (nge-bass ↔ cempreng). Beneran ngaruh ke pitch.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Expressivity")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: Binding(
                        get: { Double(voice.expressivity) },
                        set: { voice.expressivity = Float($0) }
                    ), in: 0.0...1.0, step: 0.05, onEditingChanged: { editing in
                        // Bunyi test sekali pas slider dilepas (bukan tiap geser).
                        if !editing { playSample() }
                    })
                    .tint(.white)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                // Judul + deskripsi.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Customize Your\nSiri Voice")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text("You'll hear this voice when Siri speaks.")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 32)

                Spacer()
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Orb bercahaya

struct VoiceOrbGlow: View {
    let color: Color

    var body: some View {
        ZStack {
            // Glow luar.
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: 220, height: 220)
                .blur(radius: 40)
            // Glow tengah.
            Circle()
                .fill(color.opacity(0.5))
                .frame(width: 140, height: 140)
                .blur(radius: 20)
            // Inti terang.
            Circle()
                .fill(Color.white)
                .frame(width: 80, height: 80)
                .blur(radius: 5)
            Circle()
                .fill(Color.white)
                .frame(width: 60, height: 60)
        }
    }
}
