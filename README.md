# Ai Adnan.120hz

![Build IPA](https://github.com/adnan120hz/Adnan.120hz-Ai/actions/workflows/build.yml/badge.svg)

Aplikasi chat AI untuk iOS, ditenagai API key [apinex.bond](https://apinex.bond) milikmu sendiri.
Tanpa akun, tanpa login — cuma tempel API key sekali, key disimpan di Keychain HP.

## Fitur

- **Chat AI** — pilih model dari daftar `GET /v1/models` apinex.bond, kirim chat ke `/v1/chat/completions` (streaming SSE + fallback non-streaming). Error HTTP + body API ditampilkan apa adanya.
- **Riwayat obrolan** — banyak percakapan, tersimpan lokal (SwiftData).
- **Import Source** — lampirkan txt/md/pdf; teksnya diekstrak dan dimasukkan ke konteks chat.
- **Mode Suara** — loop STT → AI → TTS on-device (Speech + AVSpeechSynthesizer). Bukan realtime duplex.
- **Foto/Video** — foto dikirim sebagai `image_url` (vision); video diekstrak maks. 4 frame. Kalau model tidak support vision, error API ditampilkan apa adanya.
- **Ingatan AI (lokal)** — fakta tentangmu diekstrak otomatis + ringkasan rolling, 100% di HP (bukan cloud). Bisa dimatikan & dihapus.
- **Kuota 25 GB** — pemakaian penyimpanan lokal ditampilkan di Pengaturan, peringatan di 90%.
- **Ganti icon** — 3 icon bawaan (Utama Navy, Hitam Swiss, Krem Editorial) via alternate icons iOS.

## API key

1. Buka aplikasi → tempel API key apinex.bond → Simpan.
2. Key hanya ada di Keychain (`kSecClassGenericPassword`, `WhenUnlockedThisDeviceOnly`).
3. Key tidak pernah di-hardcode di repo ini, tidak di-log, dan hanya dikirim sebagai `Authorization: Bearer` ke `api.apinex.bond`.

## Build

Push ke `main` (atau manual dispatch) menjalankan GitHub Actions (`macos-26`, Xcode 26):
archive unsigned → `AiAdnan120hz-unsigned.ipa` sebagai artifact.

IPA unsigned: install via sideload (Sideloadly/AltStore/TrollStore) — resign sesuai caramu sendiri.
Live API call hanya bisa dibuktikan di device fisik dengan API key milikmu.

## Struktur

```
AiAdnan120hz/
├── AiAdnan120hz.xcodeproj/
└── AiAdnan120hz/
    ├── AiAdnan120hzApp.swift
    ├── Models.swift            # SwiftData: Conversation, ChatMessage, ImageAttachment, SourceAttachment, MemoryFact
    ├── KeychainStore.swift
    ├── APIClient.swift         # URLSession → api.apinex.bond/v1
    ├── ChatViewModel.swift
    ├── SpeechService.swift     # STT + TTS
    ├── MediaService.swift      # downscale foto, ekstraksi frame video
    ├── SourceExtractor.swift   # txt/md/pdf → teks
    ├── MemoryService.swift     # ingatan lokal + ringkasan
    ├── StorageQuota.swift      # cap 25 GB
    ├── Info.plist
    ├── Assets.xcassets/        # AppIcon utama (Navy 120hz)
    ├── AltIcons/               # 2 icon alternatif
    └── Views/
```
