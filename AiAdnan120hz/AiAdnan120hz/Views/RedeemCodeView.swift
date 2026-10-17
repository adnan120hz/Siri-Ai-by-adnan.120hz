// RedeemCodeView.swift
//
// Komponen SwiftUI untuk menukar kode redeem menjadi status premium.
// Secret diambil dari Secrets.redeemSecret (di-generate saat build,
// TIDAK BOLEH di-hardcode di sini).

import SwiftUI

struct RedeemCodeView: View {

    /// Dipanggil setelah redeem sukses — parent menutup input inline supaya
    /// langsung tampil menu utama subscriptions (state terbuka).
    var onRedeemed: (() -> Void)? = nil

    @State private var code: String = ""
    @State private var isRedeeming: Bool = false
    @State private var errorMessage: String? = nil
    @State private var successMessage: String? = nil

    @ObservedObject private var premium = PremiumState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redeem code")
                .font(.headline)

            if premium.isPremium {
                Text("Premium is already active.")
                    .foregroundColor(.green)
            } else {
                TextField("Example: SIRI-X7KQ-9M2P", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                    .onChange(of: code) { _, _ in
                        errorMessage = nil
                        successMessage = nil
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
                if let successMessage {
                    Text(successMessage)
                        .foregroundColor(.green)
                        .font(.footnote)
                }

                Button {
                    redeem()
                } label: {
                    if isRedeeming {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Redeem")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRedeeming)
            }
        }
    }

    private func redeem() {
        isRedeeming = true
        errorMessage = nil
        successMessage = nil

        let entered = code
        DispatchQueue.global(qos: .userInitiated).async {
            let valid = RedeemValidator.validate(entered, secret: Secrets.redeemSecret)
            DispatchQueue.main.async {
                isRedeeming = false
                if valid {
                    PremiumState.shared.setRedeemed(true)
                    successMessage = "Valid code. Premium activated."
                    onRedeemed?()
                } else {
                    errorMessage = "Invalid redeem code."
                }
            }
        }
    }
}
