// SubscriptionsView.swift
//
// Layar Subscriptions (premium).
//
// TERKUNCI (belum redeem): daftar fitur terkunci + harga + tombol
// "Get subscriptions" (buka WhatsApp) dan "Redeem code subscriptions"
// (input kode redeem).
// TERBUKA (sudah redeem): daftar fitur + toggle yang WAJIB diaktifkan
// manual oleh user. Semua toggle default MATI dan tersimpan di UserDefaults.

import SwiftUI

struct SubscriptionsView: View {

    @ObservedObject private var premium = PremiumState.shared
    @ObservedObject private var features = PremiumFeatures.shared
    @ObservedObject private var voice = VoiceService.shared

    /// Lingkaran premium di history disembunyikan/pindah (key verbatim kontrak).
    @AppStorage("siri.premium.hideCircle") private var hideCircle = false

    @State private var showRedeemInput = false
    @State private var promptMode: PromptMode = PromptMode.selected
    @State private var customText: String = PromptMode.customText
    @State private var usedStorage: Int64 = 0

    /// URL WhatsApp VERBATIM — jangan diubah satu karakter pun.
    private static let waURLString = "https://wa.me/message/BXRJINLRDEXDI1"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if premium.isPremium {
                        unlockedSection
                    } else {
                        lockedSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
            .navigationTitle("Subscriptions")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(.systemBackground))
        }
        .onAppear {
            usedStorage = StorageQuota.usedBytes()
        }
    }

    // MARK: - State terkunci

    private var lockedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("What you get with Premium")
                .font(.headline)

            VStack(spacing: 16) {
                lockedRow(title: "File reading",
                          desc: "PDF, images, ZIP, IPA, APK, RAW read directly by the AI.")
                lockedRow(title: "Many voice options",
                          desc: "All real system voices — pick whichever you like.")
                lockedRow(title: "Prompt modes",
                          desc: "AI speaking style: Gaul, Formal, Santai, or Custom.")
                lockedRow(title: "Voice reply",
                          desc: "AI replies are read aloud in your chosen voice.")
                lockedRow(title: "Storage 50GB",
                          desc: "Storage grows from 25GB to 50GB.")
                lockedRow(title: "Unlimited messages & topics",
                          desc: "No 20-message cap and no daily limit.")
                lockedRow(title: "Own quota key",
                          desc: "Uses key 2. Key 1 turns off automatically.")
            }

            // Harga + konversi + region support.
            VStack(alignment: .leading, spacing: 4) {
                Text("Rp 5.000")
                    .font(.title)
                    .fontWeight(.bold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thailand: 9,22 THB")
                    Text("Malaysia: 1,13 MYR")
                    Text("Singapore: 0,36 SGD")
                    Text("Japan: 43,81 JPY")
                    Text("South Korea: 369,64 KRW")
                    Text("China: 1,85 CNY")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Text("via QRIS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text("Region support:")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Indonesia (QRIS)")
                    Text("Thailand (PromptPay)")
                    Text("Malaysia (DuitNow)")
                    Text("Singapore (NETS QR / SGQR)")
                    Text("Japan (JPQR Global)")
                    Text("South Korea (Seoul Pay / Jeju Pay)")
                    Text("China (Alipay / UnionPay)")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            // Tombol aksi.
            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: Self.waURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Get subscriptions")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showRedeemInput.toggle()
                } label: {
                    Text("Redeem code subscriptions")
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                if showRedeemInput {
                    RedeemCodeView(onRedeemed: { showRedeemInput = false })
                        .padding(.top, 4)
                }
            }
        }
    }

    private func lockedRow(title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(desc)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - State terbuka

    private var unlockedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Premium is active. Enable the features you want — all are off by default.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 20) {
                Toggle(isOn: $features.fileReadingEnabled) {
                    featureLabel(title: "File reading",
                                 desc: "Read PDF, images, ZIP, IPA, APK, RAW in chat.")
                }

                Toggle(isOn: $voice.voiceReplyEnabled) {
                    featureLabel(title: "Voice reply",
                                 desc: "AI replies are read aloud.")
                }

                Toggle(isOn: $features.usePremiumKey) {
                    featureLabel(title: "Other API Key",
                                 desc: "Switch to key 2, key 1 turns off automatically.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt mode")
                        .font(.body)
                        .fontWeight(.medium)
                    Picker("Prompt mode", selection: $promptMode) {
                        ForEach(PromptMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: promptMode) { _, newValue in
                        PromptMode.selected = newValue
                    }

                    if promptMode == .custom {
                        TextField("Write your own speaking style…", text: $customText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                            .onChange(of: customText) { _, newValue in
                                PromptMode.customText = newValue
                            }
                    }
                }

                Toggle(isOn: $hideCircle) {
                    featureLabel(title: "Hide subscriptions",
                                 desc: "The premium circle moves to the top-right corner.")
                }
            }

            // Storage.
            HStack {
                Text("Storage")
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text("Used \(StorageQuota.formatted(usedStorage)) of \(StorageQuota.capBytes == 50 * 1024 * 1024 * 1024 ? "50GB" : "25GB")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func featureLabel(title: String, desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
                .fontWeight(.medium)
            Text(desc)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
