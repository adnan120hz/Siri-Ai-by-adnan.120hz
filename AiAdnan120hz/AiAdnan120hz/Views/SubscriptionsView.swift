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
            Text("Yang kamu dapat dengan Premium")
                .font(.headline)

            VStack(spacing: 16) {
                lockedRow(title: "Baca file",
                          desc: "PDF, gambar, ZIP, IPA, APK, RAW langsung dibaca AI.")
                lockedRow(title: "Banyak pilihan suara",
                          desc: "Semua suara sistem asli, pilih sesukamu.")
                lockedRow(title: "Prompt modes",
                          desc: "Gaya bicara AI: Gaul, Formal, Santai, atau Custom.")
                lockedRow(title: "Voice reply",
                          desc: "Balasan AI dibacakan dengan suara pilihanmu.")
                lockedRow(title: "Storage 50GB",
                          desc: "Penyimpanan naik dari 25GB ke 50GB.")
                lockedRow(title: "Pesan & topik unlimited",
                          desc: "Tanpa batas 20 pesan dan tanpa limit harian.")
                lockedRow(title: "Key kuota sendiri",
                          desc: "Pakai Gemini key 2. Key 1 otomatis mati.")
            }

            // Harga.
            VStack(alignment: .leading, spacing: 4) {
                Text("Rp 5.000")
                    .font(.title)
                    .fontWeight(.bold)
                Text("via QRIS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Region support: Indonesia (QRIS)")
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
                    RedeemCodeView()
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
            Text("Premium aktif. Aktifkan fitur yang kamu mau — semua default mati.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 20) {
                Toggle(isOn: $features.fileReadingEnabled) {
                    featureLabel(title: "File reading",
                                 desc: "Baca PDF, gambar, ZIP, IPA, APK, RAW di chat.")
                }

                Toggle(isOn: $voice.voiceReplyEnabled) {
                    featureLabel(title: "Voice reply",
                                 desc: "Balasan AI dibacakan dengan suara.")
                }

                Toggle(isOn: $features.usePremiumKey) {
                    featureLabel(title: "Other API Key",
                                 desc: "Switch ke Gemini key 2, key 1 otomatis OFF.")
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
                        TextField("Tulis gaya bicaramu sendiri…", text: $customText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...6)
                            .onChange(of: customText) { _, newValue in
                                PromptMode.customText = newValue
                            }
                    }
                }

                Toggle(isOn: $hideCircle) {
                    featureLabel(title: "Hide subscriptions",
                                 desc: "Lingkaran premium pindah ke pojok kanan atas.")
                }
            }

            // Storage.
            HStack {
                Text("Storage")
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text("Terpakai \(StorageQuota.formatted(usedStorage)) dari \(StorageQuota.capBytes == 50 * 1024 * 1024 * 1024 ? "50GB" : "25GB")")
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
