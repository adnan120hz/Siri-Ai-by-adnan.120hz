import SwiftUI

// MARK: - Onboarding: shown once on first launch.

struct OnboardingView: View {
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("SiriOrb")
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.1), radius: 16, y: 4)

            Text("Siri Ai")
                .font(.system(size: 34, weight: .bold))

            Text("Your personal AI assistant.\nChat, analyze photos, and use your voice.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text("Created by adnan.120hz")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link("Follow on TikTok: @adnan.120hz", destination: URL(string: "https://www.tiktok.com/@adnan.120hz")!)
                .font(.subheadline)
                .foregroundStyle(.blue)

            Spacer()

            Button(action: onDone) {
                Text("Get Started")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.black)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }
}
