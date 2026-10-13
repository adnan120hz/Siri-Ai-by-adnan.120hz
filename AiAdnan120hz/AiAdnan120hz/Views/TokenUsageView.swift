import SwiftUI

// MARK: - Tampilan kuota token harian di Pengaturan.

struct TokenUsageView: View {
    @State private var used: Int = TokenUsage.usedToday()
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(TokenUsage.formatted(used)) / \(TokenUsage.formatted(TokenUsage.dailyCap))")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                Text("\(Int(TokenUsage.ratioToday() * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: TokenUsage.ratioToday())
                .tint(used >= TokenUsage.dailyCap ? .red : .accentColor)
            HStack {
                Text("Sisa: \(TokenUsage.formatted(TokenUsage.remainingToday()))")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text("Reset tiap hari")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if used >= TokenUsage.dailyCap {
                Text("Kuota harian habis. Coba lagi besok.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear {
            used = TokenUsage.usedToday()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in used = TokenUsage.usedToday() }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
