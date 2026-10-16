import SwiftUI
import AVFoundation

// MARK: - Voice: daftar SEMUA suara sistem asli + voice-reply gating
// Suara dienumerasi real dari AVSpeechSynthesisVoice.speechVoices() — tanpa hardcode.
// Tap suara → preview langsung. Tap checkmark → jadikan suara default untuk TTS.

struct VoiceModelView: View {
    @ObservedObject private var voice = VoiceService.shared
    @ObservedObject private var premium = PremiumState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []

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

    private func isSelected(_ v: AVSpeechSynthesisVoice) -> Bool {
        voice.selectedVoiceIdentifier == v.identifier
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
                    .padding(.top, 12)

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
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.horizontal, 24)
                                .padding(.top, 20)
                                .padding(.bottom, 8)

                            ForEach(group.items, id: \.identifier) { v in
                                VoiceRow(
                                    name: v.name,
                                    quality: qualityLabel(for: v),
                                    isSelected: isSelected(v),
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

                    // Voice reply (khusus premium).
                    voiceReplySection

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

    // MARK: - Voice reply

    @ViewBuilder
    private var voiceReplySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICE REPLY")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 24)
                .padding(.top, 28)

            if premium.isPremium {
                Toggle(isOn: $voice.voiceReplyEnabled) {
                    Text("Bacakan balasan AI")
                        .font(.body)
                        .foregroundStyle(.white)
                }
                .tint(.white)
                .padding(.horizontal, 24)

                Text("Balasan AI dibacakan dengan suara terpilih. Default mati — aktifkan manual kalau mau.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 24)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.5))
                    Text("Voice reply khusus Premium. Upgrade untuk membacakan balasan AI dengan suara.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

// MARK: - Baris suara

private struct VoiceRow: View {
    let name: String
    let quality: String
    let isSelected: Bool
    let onPreview: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
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
