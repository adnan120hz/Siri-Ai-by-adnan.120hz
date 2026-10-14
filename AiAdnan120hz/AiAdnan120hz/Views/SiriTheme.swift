import SwiftUI


// MARK: - Siri Ai design tokens.
// Pure-white minimal Siri aesthetic. System colors only, 8pt grid,
// native spring animations. No custom brand colors, no gradients.

enum SiriTheme {
    // MARK: Spacing (8pt grid)
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32

    // MARK: Geometry
    static let circleButton: CGFloat = 56          // round action buttons
    static let inputCorner: CGFloat = 28           // "Ask Siri" pill
    static let bubbleCorner: CGFloat = 18          // user chat bubble
    static let cardCorner: CGFloat = 28            // history cards
    static let menuCorner: CGFloat = 24            // + attachment menu
    static let maxBubbleWidth: CGFloat = 0.75      // of screen width

    // MARK: Color (semantic system colors only)
    static let circleFill = Color(.systemGray6)    // round buttons
    static let inputFill = Color(.systemGray6)     // text field pill
    static let userBubble = Color(.systemGray5)    // user message bubble

    // MARK: Motion (native springs — never plain easeInOut)
    /// Mic <-> send swap, menu pop, chip appear.
    static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.7)
    /// Bubble send/receive, sheet transitions.
    static let conversational = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// Composer pill growth — linear, never spring (fights the keyboard).
    static let composerGrow = Animation.linear(duration: 0.1)
    /// Menu + popup, attachment pop: soft bounce (0.4–0.55 / 0.7–0.85).
    static let pop = Animation.spring(response: 0.45, dampingFraction: 0.75)
    /// Liquid feel: orb, cards, list transitions.
    static let liquid = Animation.spring(response: 0.5, dampingFraction: 0.8)
    /// Keyboard show/hide + layout shifts.
    static let keyboard = Animation.spring(response: 0.4, dampingFraction: 0.8)
}

// MARK: - Liquid-glass circle fill (iOS 26+), flat fallback below.

struct SiriCircleGlassFill: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            Circle().glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(SiriTheme.circleFill)
        }
    }
}

// MARK: - Round icon button (56pt circle, liquid glass on iOS 26, black SF Symbol).

struct SiriCircleButton: View {
    let systemImage: String
    var imageSize: CGFloat = 22
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: imageSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: SiriTheme.circleButton, height: SiriTheme.circleButton)
                .background(SiriCircleGlassFill())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(systemImage))
    }
}

// MARK: - Faint Siri orb (empty-state only). Subtle liquid bounce loop.

struct SiriOrbFaint: View {
    /// Set true on the chat empty state for the signature soft bounce.
    var animate: Bool = false
    @State private var pulse = false

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Image("SiriOrb")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .glassEffect(.regular, in: Circle())
                    .opacity(0.35)
            } else {
                Image("SiriOrb")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 200)
                    .clipShape(Circle())
                    .opacity(0.15)
            }
        }
        .scaleEffect(pulse ? 1.06 : 1.0)
        .animation(
            animate
                ? .spring(response: 0.45, dampingFraction: 0.75).repeatForever(autoreverses: true)
                : nil,
            value: pulse
        )
        .onAppear { if animate { pulse = true } }
        .accessibilityHidden(true)
    }
}
