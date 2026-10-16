// RedeemValidator.swift
//
// Validasi offline kode redeem format SIRI-XXXX-XXXX.
//
// CATATAN JUJUR: validasi offline hanyalah speed-bump, BUKAN keamanan.
// Secret ikut tertanam di binary, dan siapa pun yang memegang IPA bisa
// reverse-engineer logika ini. Perlakukan skema ini sebagai gesekan UX
// untuk distribusi kode manual (mis. lewat WhatsApp), bukan sebagai
// pertahanan terhadap penyerang yang termotivasi.
//
// Skema (harus cocok byte-per-byte dengan tools/mint_redeem_code.py):
//   - Alphabet: "ABCDEFGHJKMNPQRSTUVWXYZ23456789" (31 char, tanpa 0/O/1/I/L)
//   - Payload: 4 char acak dari alphabet
//   - Checksum: 4 char, alphabet[ HMAC-SHA256(key: secret, data: payload)[i] % 31 ], i=0..<4
//   - Format: "SIRI-" + payload + "-" + checksum

import CryptoKit
import Foundation

enum RedeemValidator {

    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    /// Normalisasi input user: buang SEMUA whitespace (termasuk spasi di tengah
    /// dan newline dari paste), jadikan huruf besar.
    /// Harus identik dengan normalisasi di tools/mint_redeem_code.py:verify().
    static func normalize(_ code: String) -> String {
        code.filter { !$0.isWhitespace }.uppercased()
    }

    /// Validasi kode redeem terhadap secret.
    /// - Parameter secret: `Secrets.redeemSecret` — JANGAN hardcode nilai asli di sini.
    static func validate(_ code: String, secret: String) -> Bool {
        let normalized = normalize(code)

        // Struktur: "SIRI-XXXX-XXXX", tepat 14 karakter.
        guard normalized.count == 14 else { return false }
        let parts = normalized.split(separator: "-")
        guard parts.count == 3,
              parts[0] == "SIRI",
              parts[1].count == 4,
              parts[2].count == 4 else { return false }

        let payload = String(parts[1])
        let givenChecksum = String(parts[2])

        // Setiap char harus berasal dari alphabet.
        guard payload.allSatisfy({ alphabet.contains($0) }),
              givenChecksum.allSatisfy({ alphabet.contains($0) }) else { return false }

        // Hitung ulang checksum dari payload, bandingkan dengan constant-time compare.
        let expected = checksum(payload: payload, secret: secret)
        return constantTimeEqual(givenChecksum, expected)
    }

    // MARK: - Private

    private static func checksum(payload: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
        let macBytes = Array(mac)
        var out = ""
        out.reserveCapacity(4)
        for i in 0..<4 {
            out.append(alphabet[Int(macBytes[i]) % alphabet.count])
        }
        return out
    }

    /// Perbandingan constant-time: loop XOR atas byte UTF-8, bukan `==` biasa.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let au = Array(a.utf8)
        let bu = Array(b.utf8)
        guard au.count == bu.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(au, bu) {
            diff |= x ^ y
        }
        return diff == 0
    }
}
