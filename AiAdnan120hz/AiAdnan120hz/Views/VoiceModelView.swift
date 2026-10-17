import SwiftUI
import AVFoundation

// MARK: - Voice menu (desain user 2026-10-17)
//
// - FREE: quick-pick terbatas — English: Robot/Cowok/Cewek (3),
//   Indonesia: Robot/Cewek (2). Cowok tidak ada untuk Indonesia
//   (cuma 1 suara id-ID; speak() juga fallback ke female).
// - "All voice menu": TERKUNCI untuk free. Premium membukanya lewat
//   toggle "All voice menu" di halaman Subscriptions.
// - Daftar All: SEMUA suara sistem asli (AVSpeechSynthesisVoice),
//   dikelompokkan per bahasa, tiap suara punya warna tema deterministik
//   + nama asli sistem (nama tema yang benar) + label kualitas.
//   Tap nama → preview. Tap checkmark → jadikan default TTS.

struct VoiceModelView: View {
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var premium = PremiumState.shared
    @ObservedObject private var features = PremiumFeatures.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []

    private var allVoicesUnlocked: Bool {
        premium.isPremium && features.allVoicesEnabled
    }

    /// Suara dikelompokkan per bahasa (mis. "id-ID", "en-US"), urut abjad.
    private var groupedVoices: [(language: String, items: [AVSpeechSynthesisVoice])] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [AVSpeechSynthesisVoice]
        if q.isEmpty {
            filtered = voices
        } else {
            filtered = voices.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.language.localizedCaseInsensitiveContains(q)
            }
        }
        let groups = Dictionary(grouping: filtered, by: { $0.language })
        return groups.keys.sorted().map { lang in
            (language: lang, items: (groups[lang] ?? []).sorted { $0.name < $1.name })
        }
    }

    private func qualityLabel(for v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }

    /// Warna tema deterministik per suara (dari hash identifier) — stabil
    /// antar buka, tidak perlu disimpan.
    private func themeColor(for identifier: String) -> Color {
        var h: UInt64 = 0
        for b in identifier.utf8 { h = h &* 31 &+ UInt64(b) }
        return Color(hue: Double(h % 360) / 360.0, saturation: 0.62, brightness: 0.95)
    }

    private func isModelSelected(_ model: VoiceModel, language: VoiceLanguage) -> Bool {
        voice.selectedVoiceIdentifier.isEmpty
            && voice.voiceModel == model
            && voice.voiceLanguage == language
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Orb — identitas visual yang dikunci user.
                    VoiceOrbGlow(color: .white)
                        .frame(height: 200)
                        .padding(.top, 12)

                    Text("Voice")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)

                    // MARK: Quick-pick (free tier)
                    quickPickSection

                    // MARK: All voice menu (premium + toggle)
                    allVoicesSection

                    Spacer(minLength: 32)
                }
            }
        }
        .onAppear {
            voices = AVSpeechSynthesisVoice.speechVoices()
        }
        .onDisappear {
            voice.stopSpeaking()
        }
        .presentationDetents([.large])
    }

    // MARK: - Quick-pick

    @ViewBuilder
    private var quickPickSection: some View {
        voiceGroupHeader("ENGLISH")
        ModelRow(
            title: "Robot", subtitle: "Robotic effect", color: .gray,
            isSelected: isModelSelected(.robot, language: .english),
            onPreview: { voice.previewModel(.robot, language: .english) },
            onSelect: { selectModel(.robot, language: .english) }
        )
        ModelRow(
            title: "Cowok", subtitle: "Male voice", color: .blue,
            isSelected: isModelSelected(.male, language: .english),
            onPreview: { voice.previewModel(.male, language: .english) },
            onSelect: { selectModel(.male, language: .english) }
        )
        ModelRow(
            title: "Cewek", subtitle: "Female voice", color: .pink,
            isSelected: isModelSelected(.female, language: .english),
            onPreview: { voice.previewModel(.female, language: .english) },
            onSelect: { selectModel(.female, language: .english) }
        )

        voiceGroupHeader("INDONESIA")
        ModelRow(
            title: "Robot", subtitle: "Robotic effect", color: .gray,
            isSelected: isModelSelected(.robot, language: .indonesian),
            onPreview: { voice.previewModel(.robot, language: .indonesian) },
            onSelect: { selectModel(.robot, language: .indonesian) }
        )
        ModelRow(
            title: "Cewek", subtitle: "Female voice", color: .pink,
            isSelected: isModelSelected(.female, language: .indonesian),
            onPreview: { voice.previewModel(.female, language: .indonesian) },
            onSelect: { selectModel(.female, language: .indonesian) }
        )
    }

    private func voiceGroupHeader(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)
    }

    private func selectModel(_ model: VoiceModel, language: VoiceLanguage) {
        voice.stopSpeaking()
        voice.selectedVoiceIdentifier = ""
        voice.voiceModel = model
        voice.voiceLanguage = language
    }

    // MARK: - All voice menu

    @ViewBuilder
    private var allVoicesSection: some View {
        voiceGroupHeader("ALL VOICES")

        if allVoicesUnlocked {
            // Search.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                TextField("Cari suara", text: $query)
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.12))
            .clipShape(Capsule())
            .padding(.horizontal, 24)
            .padding(.top, 4)

            // Reset ke otomatis (kalau ada pilihan tersimpan).
            if !voice.selectedVoiceIdentifier.isEmpty {
                Button {
                    voice.stopSpeaking()
                    voice.selectedVoiceIdentifier = ""
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Otomatis (default sistem)")
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
                .padding(.top, 12)
            }

            // Daftar suara per bahasa.
            ForEach(groupedVoices, id: \.language) { group in
                VStack(alignment: .leading, spacing: 0) {
                    Text(group.language.uppercased())
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                        .padding(.bottom, 6)

                    ForEach(group.items, id: \.identifier) { v in
                        SystemVoiceRow(
                            name: v.name,
                            quality: qualityLabel(for: v),
                            color: themeColor(for: v.identifier),
                            isSelected: voice.selectedVoiceIdentifier == v.identifier,
                            onPreview: { voice.previewVoice(v) },
                            onSelect: {
                                voice.stopSpeaking()
                                voice.selectedVoiceIdentifier = v.identifier
                            }
                        )
                    }
                }
            }

            if groupedVoices.isEmpty {
                Text("Suara tidak ditemukan.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 24)
            }
        } else {
            // Terkunci: free, atau premium tapi toggle "All voice menu" mati.
            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("All voice menu")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                    Text(premium.isPremium
                         ? "Enable \"All voice menu\" in the Subscriptions page to unlock every system voice."
                         : "Premium only. Get subscriptions to unlock every system voice.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Baris quick-pick (Robot / Cowok / Cewek)

private struct ModelRow: View {
    let title: String
    let subtitle: String
    let color: Color
    let isSelected: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 34, height: 34)
            // Tap teks → preview.
            Button(action: onPreview) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Tap checkmark → pilih.
            Button(action: onSelect) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                    if isSelected {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isSelected ? "Suara terpilih" : "Pilih suara \(title)"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
    }
}

// MARK: - Baris suara sistem (All voice menu)

private struct SystemVoiceRow: View {
    let name: String
    let quality: String
    let color: Color
    let isSelected: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(name.prefix(1)))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black.opacity(0.6))
                )
            // Tap nama → preview langsung.
            Button(action: onPreview) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.white)
                    Text(quality)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Tap checkmark → jadikan default.
            Button(action: onSelect) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.4), lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                    if isSelected {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.black)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isSelected ? "Suara terpilih" : "Pilih suara \(name)"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
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
