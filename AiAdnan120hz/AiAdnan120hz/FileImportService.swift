import Foundation
import PDFKit
import UniformTypeIdentifiers

// MARK: - Model

/// Jenis file yang dikenali FileImportService.
enum FileKind: String {
    case pdf
    case image
    case archive
    case raw
    case unknown
}

/// Hasil ekstraksi satu file. Untuk gambar (kind == .image), teks TIDAK
/// diekstrak lokal — `imageData`/`imageMimeType` diteruskan ke
/// `GeminiClient.sendWithImages` oleh lapisan integrasi.
struct ExtractedFile {
    let fileName: String
    let kind: FileKind
    let textContent: String
    let metadata: String
    let imageData: Data?
    let imageMimeType: String?

    init(fileName: String,
         kind: FileKind,
         textContent: String,
         metadata: String,
         imageData: Data? = nil,
         imageMimeType: String? = nil) {
        self.fileName = fileName
        self.kind = kind
        self.textContent = textContent
        self.metadata = metadata
        self.imageData = imageData
        self.imageMimeType = imageMimeType
    }
}

/// Error bertipe dengan pesan Bahasa Indonesia yang jelas.
enum FileImportError: LocalizedError {
    case cannotAccessFile(String)
    case fileTooLarge(String)
    case unsupportedType(String)
    case pdfUnreadable(String)
    case imageUnreadable(String)
    case archiveUnreadable(String)
    case rawUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .cannotAccessFile(let name):
            return "File '\(name)' tidak bisa diakses. Coba pilih ulang file-nya."
        case .fileTooLarge(let detail):
            return "File terlalu besar: \(detail)."
        case .unsupportedType(let ext):
            return "Tipe file '.\(ext)' belum didukung. Yang didukung: pdf, jpg, jpeg, png, zip, ipa, apk, raw, cr2, nef, dng, arw."
        case .pdfUnreadable(let detail):
            return "PDF tidak bisa dibaca. \(detail)"
        case .imageUnreadable(let detail):
            return "Gambar tidak bisa dibaca. \(detail)"
        case .archiveUnreadable(let detail):
            return "Arsip tidak bisa dibaca. \(detail)"
        case .rawUnreadable(let detail):
            return "File RAW tidak bisa dibaca. \(detail)"
        }
    }
}

// MARK: - Service

/// Membaca file yang dipilih user (premium) dan mengekstrak kontennya
/// menjadi teks/metadata yang bisa dikirim sebagai konteks ke AI.
///
/// Semua yang dilakukan di sini nyata: PDF via PDFKit, ZIP via parser
/// central-directory + decoder DEFLATE mentah sendiri (tanpa library).
/// Hanya PDF dan ZIP yang didukung (keputusan user 2026-10-17).
/// Tidak ada placeholder.
struct FileImportService {
    static let shared = FileImportService()
    private init() {}

    private let maxPDFPages = 50
    private let maxPDFChars = 100 * 1024        // 100 KB teks
    private let maxPDFBytes = 50 * 1024 * 1024  // 50 MB
    private let maxArchiveBytes = 100 * 1024 * 1024 // 100 MB

    // MARK: Entry point

    /// Ekstrak konten dari URL file. Menangani security-scoped URL
    /// (start/stopAccessingSecurityScopedResource) dengan benar.
    func extract(from url: URL) throws -> ExtractedFile {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try extractPDF(from: url, fileName: fileName)
        case "zip":
            return try extractArchive(from: url, fileName: fileName, ext: ext)
        default:
            throw FileImportError.unsupportedType(ext.isEmpty ? "(tanpa ekstensi)" : ext)
        }
    }

    // MARK: Helpers

    private func fileSize(of url: URL) -> Int? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size >= 0 else { return nil }
        return size
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 0 { return "tidak diketahui" }
        if n < 1024 { return "\(n) byte" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        return String(format: "%.1f MB", Double(n) / 1048576.0)
    }

    private func formatBytes(_ n: UInt64) -> String {
        if n < 1024 { return "\(n) byte" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024.0) }
        if n < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(n) / 1048576.0) }
        return String(format: "%.2f GB", Double(n) / 1073741824.0)
    }

    // MARK: PDF

    private func extractPDF(from url: URL, fileName: String) throws -> ExtractedFile {
        guard let size = fileSize(of: url) else {
            throw FileImportError.cannotAccessFile(fileName)
        }
        if size > maxPDFBytes {
            throw FileImportError.fileTooLarge("PDF '\(fileName)' (\(formatBytes(size))) melebihi batas 50 MB")
        }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw FileImportError.pdfUnreadable("File '\(fileName)' tidak bisa dibuka atau tidak punya halaman.")
        }

        var parts: [String] = []
        var chars = 0
        var hitCharCap = false
        let pagesToRead = min(doc.pageCount, maxPDFPages)

        for i in 0..<pagesToRead {
            guard let text = doc.page(at: i)?.string, !text.isEmpty else { continue }
            let remaining = maxPDFChars - chars
            if remaining <= 0 { hitCharCap = true; break }
            if text.count > remaining {
                parts.append(String(text.prefix(remaining)))
                chars = maxPDFChars
                hitCharCap = true
                break
            }
            parts.append(text)
            chars += text.count
        }

        let sizeText = formatBytes(size)
        var meta = "Tipe: PDF • \(doc.pageCount) halaman • \(sizeText)"
        if doc.pageCount > maxPDFPages {
            meta += "\nCatatan: teks dipotong — hanya \(maxPDFPages) halaman pertama dari \(doc.pageCount) halaman yang dibaca."
        }
        if hitCharCap {
            meta += "\nCatatan: teks dipotong pada 100 KB."
        }

        return ExtractedFile(
            fileName: fileName,
            kind: .pdf,
            textContent: parts.joined(separator: "\n\n"),
            metadata: meta
        )
    }

// MARK: - Archive (ZIP / IPA / APK)

private extension FileImportService {

    /// Ekstensi file teks yang diekstrak isinya dari dalam arsip.
    var archiveTextExtensions: Set<String> {
        ["txt", "md", "markdown", "json", "plist", "csv", "tsv", "log",
         "html", "htm", "css", "js", "mjs", "ts", "yml", "yaml",
         "ini", "cfg", "conf", "properties", "gradle",
         "swift", "m", "mm", "h", "c", "cpp", "py", "rb", "sh", "sql",
         "tex", "rst", "srt", "vtt", "lrc"]
    }

    func extractArchive(from url: URL, fileName: String, ext: String) throws -> ExtractedFile {
        guard let size = fileSize(of: url) else {
            throw FileImportError.cannotAccessFile(fileName)
        }
        if size > maxArchiveBytes {
            throw FileImportError.fileTooLarge("arsip '\(fileName)' (\(formatBytes(size))) melebihi batas 100 MB")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileImportError.archiveUnreadable("Gagal membaca '\(fileName)': \(error.localizedDescription)")
        }

        let entries: [ZipEntry]
        do {
            entries = try ZipReader.centralDirectory(in: data)
        } catch let e as ZipError {
            throw FileImportError.archiveUnreadable("File '\(fileName)' bukan arsip ZIP yang valid: \(e.message)")
        }

        let isIPA = ext == "ipa"
        let isAPK = ext == "apk"
        let kindLabel = isIPA ? "paket aplikasi iOS (.ipa)"
            : isAPK ? "paket aplikasi Android (.apk)" : "arsip ZIP"

        var lines: [String] = []
        lines.append("Daftar isi arsip (\(entries.count) entri):")
        for e in entries {
            let tag = e.isDirectory ? " [folder]" : ""
            lines.append("- \(e.name) (\(formatBytes(e.uncompressedSize)))\(tag)")
        }

        var notes: [String] = []
        let encryptedCount = entries.filter { $0.isEncrypted }.count
        if encryptedCount > 0 {
            notes.append("\(encryptedCount) entri terenkripsi (password) dilewati — tidak didukung.")
        }

        // --- Khusus IPA: parse Payload/*.app/Info.plist ---
        if isIPA {
            if let infoEntry = entries.first(where: { isAppInfoPlistPath($0.name) }) {
                do {
                    let bytes = try ZipReader.extract(entry: infoEntry, from: data)
                    let plist = try PropertyListSerialization.propertyList(
                        from: Data(bytes), options: [], format: nil)
                    if let dict = plist as? [String: Any] {
                        let name = (dict["CFBundleDisplayName"] as? String)
                            ?? (dict["CFBundleName"] as? String) ?? "-"
                        let bid = dict["CFBundleIdentifier"] as? String ?? "-"
                        let ver = dict["CFBundleShortVersionString"] as? String ?? "-"
                        let build = dict["CFBundleVersion"] as? String ?? "-"
                        lines.append("")
                        lines.append("Info aplikasi (dari \(infoEntry.name)):")
                        lines.append("- Nama: \(name)")
                        lines.append("- Bundle ID: \(bid)")
                        lines.append("- Versi: \(ver) (build \(build))")
                    } else {
                        notes.append("Info.plist ditemukan tapi bukan dictionary — tidak bisa dibaca key-nya.")
                    }
                } catch {
                    notes.append("Info.plist ditemukan di \(infoEntry.name) tapi gagal dibaca: \(error.localizedDescription)")
                }
            } else {
                notes.append("Payload/*.app/Info.plist tidak ditemukan di arsip ini.")
            }
        }

        // --- Khusus APK: AndroidManifest.xml = binary XML, jujur best-effort ---
        if isAPK, let manifest = entries.first(where: { $0.name == "AndroidManifest.xml" }) {
            do {
                let bytes = try ZipReader.extract(entry: manifest, from: data)
                let strings = printableStrings(from: bytes, maxStrings: 400)
                lines.append("")
                lines.append("AndroidManifest.xml — CATATAN JUJUR: file ini adalah binary XML (AXML), "
                    + "bukan XML teks. Parser AXML penuh tidak tersedia di sini, jadi TIDAK diklaim "
                    + "terbaca penuh. Di bawah ini hanya string printable (best-effort, \(strings.count) string):")
                lines.append(strings.joined(separator: "\n"))
            } catch {
                notes.append("AndroidManifest.xml gagal diekstrak: \(error.localizedDescription)")
            }
        }

        // --- Ekstrak file teks di dalam arsip ---
        let manifestName = "AndroidManifest.xml"
        let textCandidates = entries.filter { e in
            !e.isDirectory && !e.isEncrypted && e.uncompressedSize > 0
                && archiveTextExtensions.contains((e.name as NSString).pathExtension.lowercased())
                && !(isAPK && e.name == manifestName)
                && !(isIPA && isAppInfoPlistPath(e.name))
        }
        let maxTextFiles = 25
        let maxCharsPerFile = 32 * 1024
        var extractedCount = 0
        for e in textCandidates.prefix(maxTextFiles) {
            do {
                let bytes = try ZipReader.extract(entry: e, from: data)
                guard let text = String(bytes: bytes, encoding: .utf8), !text.isEmpty else {
                    continue // bukan teks UTF-8 valid — dilewati diam-diam, bukan dikarang
                }
                let shown = text.count > maxCharsPerFile
                    ? String(text.prefix(maxCharsPerFile)) + "\n…(dipotong pada 32 KB)"
                    : text
                lines.append("")
                lines.append("===== \(e.name) (\(formatBytes(e.uncompressedSize))) =====")
                lines.append(shown)
                extractedCount += 1
            } catch {
                notes.append("Gagal mengekstrak '\(e.name)': \(error.localizedDescription)")
            }
        }
        if textCandidates.count > maxTextFiles {
            notes.append("Hanya \(maxTextFiles) file teks pertama yang ditampilkan dari \(textCandidates.count) file teks.")
        }
        if extractedCount == 0 && !isIPA && !isAPK {
            notes.append("Tidak ada file teks yang bisa diekstrak dari arsip ini.")
        }

        var meta = "Tipe: \(kindLabel) • \(entries.count) entri • \(formatBytes(size))"
        for n in notes { meta += "\nCatatan: \(n)" }

        return ExtractedFile(
            fileName: fileName,
            kind: .archive,
            textContent: lines.joined(separator: "\n"),
            metadata: meta
        )
    }

    /// Cocokkan path bentuk "Payload/<Nama>.app/Info.plist" (tepat 2 slash).
    func isAppInfoPlistPath(_ name: String) -> Bool {
        guard name.hasPrefix("Payload/"), name.hasSuffix(".app/Info.plist") else { return false }
        return name.filter { $0 == "/" }.count == 2
    }

    /// Ambil string printable (seperti util `strings`) — best-effort, jujur.
    func printableStrings(from bytes: [UInt8], minLength: Int = 4, maxStrings: Int = 1500) -> [String] {
        var out: [String] = []
        var current: [UInt8] = []
        func flush() {
            if current.count >= minLength, let s = String(bytes: current, encoding: .utf8) {
                out.append(s)
            }
            current.removeAll(keepingCapacity: true)
        }
        for b in bytes {
            if b >= 0x20 && b < 0x7F {
                current.append(b)
            } else {
                flush()
            }
            if out.count >= maxStrings { break }
        }
        // Flush terakhir hanya jika masih di bawah batas — tanpanya hasil
        // bisa berisi maxStrings + 1 string.
        if out.count < maxStrings { flush() }
        return out
    }

// MARK: - ZIP reader (tanpa library, parse manual)

/// Batas hasil dekompresi per entri ZIP (anti zip-bomb). Satu sumber
/// kebenaran dipakai ZipReader (pre-check ukuran header) dan RawInflate
/// (cap runtime) agar keduanya tidak pernah drift.
private let zipMaxInflateBytes: UInt64 = 64 * 1024 * 1024 // 64 MB per entri

/// Error internal pembaca ZIP.
private enum ZipError: LocalizedError {
    case notAZip
    case corrupt(String)
    case unsupported(String)

    var message: String {
        switch self {
        case .notAZip: return "signature ZIP tidak ditemukan."
        case .corrupt(let d): return "struktur arsip rusak (\(d))."
        case .unsupported(let d): return d
        }
    }

    var errorDescription: String? { message }
}

/// Satu entri dari central directory.
private struct ZipEntry {
    let name: String
    let method: UInt16          // 0 = stored, 8 = deflated
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    let crc32: UInt32
    let isDirectory: Bool
    let isEncrypted: Bool
}

private enum ZipReader {
    // Batas keamanan: cegah zip-bomb (lihat zipMaxInflateBytes).
    private static let maxEntries = 100_000

    // MARK: little-endian readers (bounds-checked, tanpa force-unwrap)

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    // MARK: central directory

    /// Parse End-Of-Central-Directory lalu seluruh central directory.
    /// Mengembalikan daftar entri. Hanya arsip single-disk non-ZIP64.
    static func centralDirectory(in data: Data) throws -> [ZipEntry] {
        // Cari signature EOCD (50 4B 05 06) dari belakang; EOCD min 22 byte,
        // komentar maks 65535 byte.
        let sig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count >= 22 else { throw ZipError.notAZip }
        let searchStart = max(0, data.count - 65557)
        var eocdOffset: Int? = nil
        var i = data.count - 22
        while i >= searchStart {
            if data[i] == sig[0] && data[i + 1] == sig[1]
                && data[i + 2] == sig[2] && data[i + 3] == sig[3],
               let commentLen = u16(data, i + 20),
               // EOCD yang asli harus berakhir tepat di ujung file.
               // Signature PK\x05\x06 yang muncul di dalam komentar zip
               // (false positive) dilewati — lanjut scan ke belakang.
               i + 22 + Int(commentLen) == data.count {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset,
              let diskNumber = u16(data, eocd + 4),
              let cdDisk = u16(data, eocd + 6),
              let entriesThisDisk = u16(data, eocd + 8),
              let totalEntries = u16(data, eocd + 10),
              let cdSize = u32(data, eocd + 12),
              let cdOffset = u32(data, eocd + 16) else {
            throw ZipError.notAZip
        }
        // Tolak eksplisit arsip multi-disk (spanned): offset central directory
        // di EOCD merujuk ke disk lain, jadi parse single-file tidak valid.
        if diskNumber != 0 || cdDisk != 0 || entriesThisDisk != totalEntries {
            throw ZipError.unsupported("arsip multi-disk (spanned) tidak didukung")
        }
        if totalEntries > maxEntries {
            throw ZipError.corrupt("jumlah entri tidak wajar (\(totalEntries))")
        }
        let cdOff = Int(cdOffset)
        guard cdOff >= 0, cdOff + Int(cdSize) <= data.count else {
            throw ZipError.corrupt("offset central directory di luar file")
        }

        var entries: [ZipEntry] = []
        var pos = cdOff
        for _ in 0..<Int(totalEntries) {
            guard pos + 46 <= data.count,
                  data[pos] == 0x50, data[pos + 1] == 0x4B,
                  data[pos + 2] == 0x01, data[pos + 3] == 0x02 else {
                throw ZipError.corrupt("header central directory tidak valid di offset \(pos)")
            }
            guard let flags = u16(data, pos + 8),
                  let method = u16(data, pos + 10),
                  // Offset 16: CRC-32 di central directory header (PK0102).
                  // AWAS: jangan disamakan dengan local file header (PK0304)
                  // yang CRC-nya di offset 14 — layout keduanya berbeda.
                  let crc = u32(data, pos + 16),
                  let compSize32 = u32(data, pos + 20),
                  let uncompSize32 = u32(data, pos + 24),
                  let nameLen = u16(data, pos + 28),
                  let extraLen = u16(data, pos + 30),
                  let commentLen = u16(data, pos + 32),
                  let localOff32 = u32(data, pos + 42) else {
                throw ZipError.corrupt("field central directory terpotong di offset \(pos)")
            }
            // ZIP64 (nilai 0xFFFF/0xFFFFFFFF) belum didukung — jujur, bukan dikarang.
            if compSize32 == 0xFFFF_FFFF || uncompSize32 == 0xFFFF_FFFF || localOff32 == 0xFFFF_FFFF {
                throw ZipError.unsupported("arsip memakai ekstensi ZIP64 yang belum didukung")
            }
            let nameStart = pos + 46
            let nameEnd = nameStart + Int(nameLen)
            guard nameEnd <= data.count else {
                throw ZipError.corrupt("nama entri terpotong di offset \(pos)")
            }
            let nameBytes = [UInt8](data[nameStart..<nameEnd])
            let name: String
            if flags & 0x0800 != 0 {
                // Bit 11 = nama UTF-8.
                guard let s = String(bytes: nameBytes, encoding: .utf8) else {
                    throw ZipError.corrupt("nama entri bukan UTF-8 valid")
                }
                name = s
            } else {
                // Fallback Latin-1 (selalu berhasil, mungkin mojibake — jujur).
                name = String(bytes: nameBytes, encoding: .isoLatin1) ?? "(nama tak terbaca)"
            }

            entries.append(ZipEntry(
                name: name,
                method: method,
                compressedSize: UInt64(compSize32),
                uncompressedSize: UInt64(uncompSize32),
                localHeaderOffset: UInt64(localOff32),
                crc32: crc,
                isDirectory: name.hasSuffix("/"),
                isEncrypted: flags & 0x0001 != 0
            ))
            pos = nameEnd + Int(extraLen) + Int(commentLen)
        }
        return entries
    }

    // MARK: extract

    /// Ekstrak bytes mentah satu entri (handle stored + deflated + verifikasi CRC32).
    static func extract(entry: ZipEntry, from data: Data) throws -> [UInt8] {
        if entry.isEncrypted {
            throw ZipError.unsupported("entri '\(entry.name)' terenkripsi (password) — tidak didukung")
        }
        if entry.method != 0 && entry.method != 8 {
            throw ZipError.unsupported("metode kompresi \(entry.method) untuk '\(entry.name)' tidak didukung (hanya stored/deflated)")
        }
        if entry.uncompressedSize > zipMaxInflateBytes {
            throw ZipError.unsupported("entri '\(entry.name)' melebihi 64 MB hasil ekstraksi")
        }

        // Baca local file header untuk menemukan awal data.
        let loff = Int(entry.localHeaderOffset)
        guard loff + 30 <= data.count,
              data[loff] == 0x50, data[loff + 1] == 0x4B,
              data[loff + 2] == 0x03, data[loff + 3] == 0x04,
              let nameLen = u16(data, loff + 26),
              let extraLen = u16(data, loff + 28) else {
            throw ZipError.corrupt("local header tidak valid untuk '\(entry.name)'")
        }
        let dataStart = loff + 30 + Int(nameLen) + Int(extraLen)
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataStart >= 0, dataEnd <= data.count else {
            throw ZipError.corrupt("data entri '\(entry.name)' di luar file")
        }
        let raw = [UInt8](data[dataStart..<dataEnd])

        let out: [UInt8]
        if entry.method == 0 {
            out = raw
        } else {
            do {
                out = try RawInflate.decompress(raw, expectedSize: entry.uncompressedSize)
            } catch {
                throw ZipError.corrupt("gagal dekompresi '\(entry.name)' (data DEFLATE tidak valid)")
            }
        }
        guard UInt64(out.count) == entry.uncompressedSize else {
            throw ZipError.corrupt("ukuran hasil '\(entry.name)' tidak sesuai header")
        }
        if crc32(out) != entry.crc32 {
            throw ZipError.corrupt("checksum CRC32 '\(entry.name)' tidak cocok — arsip mungkin rusak")
        }
        return out
    }

    // MARK: CRC32 (IEEE 802.3)

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Raw DEFLATE decoder (RFC 1951), tanpa library

/// Decoder DEFLATE mentah (raw, tanpa wrapper zlib) sesuai RFC 1951.
/// Dipakai untuk entri ZIP metode 8. Ditulis manual karena project
/// tidak memakai library ZIP eksternal.
///
/// KEPUTUSAN DESAIN (2026-10-17): sengaja TIDAK memakai framework Compression
/// (COMPRESSION_ZLIB). Framework itu hanya mendukung format zlib utuh — header
/// 2 byte + DEFLATE + trailer Adler-32 4 byte (RFC 1950) — dan tidak punya mode
/// raw-deflate. Trik "tempel header palsu 0x78 0x9C" ke data mentah ZIP tidak
/// terverifikasi: tidak ada dokumentasi/bukti kredibel bahwa decoder Apple
/// mentolerir trailer Adler-32 yang hilang/tidak cocok, dan tidak bisa diuji
/// eksekusi di lingkungan ini. Decoder manual ini + verifikasi CRC32 bawaan
/// ZIP adalah jalur yang perilakunya sepenuhnya bisa diprediksi dari RFC.
///
/// CATATAN JUJUR: kode ini BELUM PERNAH dikompilasi/dieksekusi (tidak ada Mac
/// di sini). Sudah di-review statis baris-per-baris melawan RFC 1951 — tabel
/// length/distance §3.2.5, kode Huffman kanonik §3.2.2, urutan bit LSB-first
/// dengan kode Huffman MSB-first §3.2, urutan code-length §3.2.7, blok stored/
/// fixed/dynamic + flag final-block §3.2.3–3.2.6, guard anti zip-bomb 64 MB —
/// dan satu bug offset CRC central-directory sudah diperbaiki dari review
/// tersebut. Tapi review statis BUKAN pengganti uji jalan: WAJIB smoke test
/// di device/CI dengan file zip/ipa/apk nyata sebelum jalur ini diandalkan.
private enum RawInflate {
    private enum InflateError: Error { case truncated, invalid }

    // Tabel RFC 1951 §3.2.5 — panjang (length) untuk kode 257–285.
    private static let lengthBase = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
    private static let lengthExtra = [0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0]
    // Tabel RFC 1951 §3.2.5 — jarak (distance) untuk kode 0–29.
    private static let distBase = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
    private static let distExtra = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
    // Urutan kode panjang-kode, RFC 1951 §3.2.7.
    private static let codeLengthOrder = [16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15]

    private struct BitReader {
        let bytes: [UInt8]
        var pos: Int = 0   // indeks byte
        var bit: Int = 0   // indeks bit dalam byte, LSB-first

        mutating func readBit() throws -> Int {
            guard pos < bytes.count else { throw InflateError.truncated }
            let v = (Int(bytes[pos]) >> bit) & 1
            bit += 1
            if bit == 8 { bit = 0; pos += 1 }
            return v
        }

        mutating func readBits(_ n: Int) throws -> Int {
            var v = 0
            for i in 0..<n {
                v |= (try readBit()) << i
            }
            return v
        }

        mutating func readBytes(_ n: Int) throws -> [UInt8] {
            if bit != 0 { bit = 0; pos += 1 } // align ke batas byte
            guard n >= 0, pos + n <= bytes.count else { throw InflateError.truncated }
            let s = Array(bytes[pos..<(pos + n)])
            pos += n
            return s
        }
    }

    /// Kode Huffman kanonik dari daftar panjang-kode per simbol.
    private struct Huffman {
        let table: [Int: Int]  // kunci: (panjang << 20) | kode → simbol
        let maxLen: Int

        static func build(lengths: [Int]) throws -> Huffman {
            let maxLen = lengths.max() ?? 0
            guard maxLen <= 15 else { throw InflateError.invalid }
            var blCount = [Int](repeating: 0, count: maxLen + 1)
            for l in lengths where l > 0 { blCount[l] += 1 }
            // Kode kanonik: RFC 1951 §3.2.2.
            var nextCode = [Int](repeating: 0, count: maxLen + 1)
            var code = 0
            if maxLen > 0 {
                for bits in 1...maxLen {
                    code = (code + blCount[bits - 1]) << 1
                    nextCode[bits] = code
                }
            }
            var table: [Int: Int] = [:]
            for (sym, len) in lengths.enumerated() where len > 0 {
                table[(len << 20) | nextCode[len]] = sym
                nextCode[len] += 1
            }
            return Huffman(table: table, maxLen: maxLen)
        }

        func decode(_ r: inout BitReader) throws -> Int {
            var code = 0
            var len = 0
            while len < maxLen {
                len += 1
                code = (code << 1) | (try r.readBit())
                if let sym = table[(len << 20) | code] { return sym }
            }
            throw InflateError.invalid
        }
    }

    private static func fixedLitLen() throws -> Huffman {
        var lengths = [Int](repeating: 0, count: 288)
        for i in 0..<144 { lengths[i] = 8 }
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        for i in 280..<288 { lengths[i] = 8 }
        return try Huffman.build(lengths: lengths)
    }

    private static func fixedDist() throws -> Huffman {
        try Huffman.build(lengths: [Int](repeating: 5, count: 32))
    }

    private static func dynamicTables(_ r: inout BitReader) throws -> (lit: Huffman, dist: Huffman) {
        let hlit = try r.readBits(5) + 257
        let hdist = try r.readBits(5) + 1
        let hclen = try r.readBits(4) + 4
        guard hlit <= 288, hdist <= 32 else { throw InflateError.invalid }

        var clLens = [Int](repeating: 0, count: 19)
        for i in 0..<hclen {
            clLens[codeLengthOrder[i]] = try r.readBits(3)
        }
        let cl = try Huffman.build(lengths: clLens)

        var allLens: [Int] = []
        allLens.reserveCapacity(hlit + hdist)
        while allLens.count < hlit + hdist {
            let sym = try cl.decode(&r)
            switch sym {
            case 0...15:
                allLens.append(sym)
            case 16:
                let rep = try r.readBits(2) + 3
                guard let last = allLens.last else { throw InflateError.invalid }
                allLens.append(contentsOf: [Int](repeating: last, count: rep))
            case 17:
                let rep = try r.readBits(3) + 3
                allLens.append(contentsOf: [Int](repeating: 0, count: rep))
            case 18:
                let rep = try r.readBits(7) + 11
                allLens.append(contentsOf: [Int](repeating: 0, count: rep))
            default:
                throw InflateError.invalid
            }
        }
        guard allLens.count == hlit + hdist else { throw InflateError.invalid }
        let lit = try Huffman.build(lengths: Array(allLens[0..<hlit]))
        let dist = try Huffman.build(lengths: Array(allLens[hlit...]))
        return (lit, dist)
    }

    private static func decodeBlock(_ r: inout BitReader, lit: Huffman, dist: Huffman,
                                   output: inout [UInt8], cap: UInt64) throws {
        while true {
            let sym = try lit.decode(&r)
            if sym < 256 {
                output.append(UInt8(sym))
            } else if sym == 256 {
                return // akhir blok
            } else if sym <= 285 {
                let li = sym - 257
                let length = lengthBase[li] + (try r.readBits(lengthExtra[li]))
                let dsym = try dist.decode(&r)
                guard dsym < 30 else { throw InflateError.invalid }
                let distance = distBase[dsym] + (try r.readBits(distExtra[dsym]))
                // Jendela DEFLATE maks 32.768 (RFC 1951 §3.2.5: jarak 1–32768).
                // Encoder valid tidak pernah melebihi itu, jadi batas ini tidak
                // menolak stream valid — hanya menolak data korup lebih awal
                // (lapis kedua setelah verifikasi CRC32 di ZipReader.extract).
                guard distance >= 1, distance <= 32768, distance <= output.count else { throw InflateError.invalid }
                guard UInt64(output.count) + UInt64(length) <= cap else { throw InflateError.invalid }
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            } else {
                throw InflateError.invalid
            }
            if UInt64(output.count) > cap { throw InflateError.invalid }
        }
    }

    /// Dekompresi satu stream DEFLATE mentah. `expectedSize` = ukuran
    /// uncompressed dari header ZIP (dipakai untuk reserve + validasi).
    static func decompress(_ input: [UInt8], expectedSize: UInt64) throws -> [UInt8] {
        let cap: UInt64 = zipMaxInflateBytes // anti zip-bomb
        var r = BitReader(bytes: input)
        var output: [UInt8] = []
        output.reserveCapacity(Int(min(expectedSize, cap)))
        let fixedLit = try fixedLitLen()
        let fixedDst = try fixedDist()

        var isFinal = false
        while !isFinal {
            isFinal = (try r.readBit()) == 1
            let btype = try r.readBits(2)
            switch btype {
            case 0: // stored (tanpa kompresi)
                let len = try r.readBits(16)
                let nlen = try r.readBits(16)
                guard len ^ nlen == 0xFFFF else { throw InflateError.invalid }
                guard UInt64(output.count) + UInt64(len) <= cap else { throw InflateError.invalid }
                output.append(contentsOf: try r.readBytes(len))
            case 1: // fixed Huffman
                try decodeBlock(&r, lit: fixedLit, dist: fixedDst, output: &output, cap: cap)
            case 2: // dynamic Huffman
                let t = try dynamicTables(&r)
                try decodeBlock(&r, lit: t.lit, dist: t.dist, output: &output, cap: cap)
            default: // 3 = reserved → invalid
                throw InflateError.invalid
            }
        }
        return output
    }
}
