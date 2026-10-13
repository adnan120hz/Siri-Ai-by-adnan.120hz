import SwiftUI

// MARK: - Glowing Siri orb (iOS 27 style): layered radial gradients + slow drift.
// Pure SwiftUI, no assets, works in dark & light.

struct SiriOrbView: View {
    var size: CGFloat = 220
    var animating: Bool = true

    @State private var t: Double = 0

    var body: some View {
        ZStack {
            // Outer soft halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.siriGlowPink.opacity(0.35), .siriGlowBlue.opacity(0.12), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.7
                    )
                )
                .frame(width: size * 1.4, height: size * 1.4)
                .blur(radius: 18)
                .scaleEffect(1 + 0.06 * Darwin.sin(t * 1.3))
                .offset(x: 8 * Darwin.sin(t * 0.7), y: 6 * Darwin.cos(t * 0.9))

            // Mid swirl — blue/violet
            Circle()
                .fill(
                    AngularGradient(
                        colors: [.siriGlowBlue, .siriGlowViolet, .siriGlowPink, .siriGlowBlue],
                        center: .center, angle: .degrees(t * 24)
                    )
                )
                .frame(width: size, height: size)
                .blur(radius: 26)
                .opacity(0.85)

            // Inner warm core
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, .siriGlowPink.opacity(0.7), .clear],
                        center: .center, startRadius: 0, endRadius: size * 0.42
                    )
                )
                .frame(width: size * 0.84, height: size * 0.84)
                .blur(radius: 14)
                .scaleEffect(1 + 0.08 * Darwin.sin(t * 2.1 + 1))

            // Bright center
            Circle()
                .fill(RadialGradient(colors: [.white, .white.opacity(0.55), .clear],
                                     center: .center, startRadius: 0, endRadius: size * 0.22))
                .frame(width: size * 0.44, height: size * 0.44)
                .blur(radius: 6)
        }
        .frame(width: size * 1.4, height: size * 1.4)
        .onAppear {
            guard animating else { return }
            withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                t = 100
            }
        }
    }
}

// MARK: - Siri palette

extension Color {
    static let siriGlowBlue = Color(red: 0.35, green: 0.55, blue: 1.0)
    static let siriGlowViolet = Color(red: 0.62, green: 0.35, blue: 1.0)
    static let siriGlowPink = Color(red: 1.0, green: 0.45, blue: 0.75)
    static let siriVoiceGreen = Color(red: 0.30, green: 0.85, blue: 0.35)
    static let siriVoiceYellow = Color(red: 1.0, green: 0.80, blue: 0.25)
    static let siriVoiceOrange = Color(red: 1.0, green: 0.55, blue: 0.15)
    static let siriVoiceRed = Color(red: 1.0, green: 0.30, blue: 0.30)
    static let siriVoicePurple = Color(red: 0.70, green: 0.30, blue: 1.0)
}
