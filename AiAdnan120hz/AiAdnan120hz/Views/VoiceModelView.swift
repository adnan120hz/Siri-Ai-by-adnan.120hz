import SwiftUI

// MARK: - Voice Model: pilih suara AI (Robot / Cowok / Cewek)
// UI ala iOS 27: orb bercahaya di atas, 3 warna, slider pace.
// Beda warna = beda suara. Tanpa menu bahasa (AI menyesuaikan sendiri).

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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Orb bercahaya — warna berubah sesuai model terpilih.
                VoiceOrbGlow(color: color(for: voice.voiceModel))
                    .frame(height: 280)
                    .padding(.top, 20)

                // Label "Voice" (tanpa menu bahasa).
                HStack {
                    Text("Voice")
                        .font(.title2)
                        .foregroundStyle(.white)
                    Spacer()
                    Text(voice.voiceModel.title)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.15))
                        .clipShape(Capsule())
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
                            voice.speak("Halo, ini suara \(model.title).")
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
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

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
