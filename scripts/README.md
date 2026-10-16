# scripts/

## generate_secrets.py — generator `Secrets.swift`

`Secrets.swift` (di `AiAdnan120hz/AiAdnan120hz/`) **di-generate saat build** dari
environment variables dan **tidak pernah di-commit** (masuk `.gitignore`).
Contoh strukturnya ada di `Secrets.swift.template`.

### Environment variables

| Variable               | Untuk                    |
|------------------------|--------------------------|
| `GEMINI_API_KEY_FREE`    | Key Gemini tier free     |
| `GEMINI_API_KEY_PREMIUM` | Key Gemini tier premium  |
| `REDEEM_SECRET`          | Secret validasi redeem   |

### Lokal (development)

```bash
python3 scripts/generate_secrets.py
```

Env yang kosong otomatis diganti dummy (`DUMMY_FREE_KEY`, dst.) — cukup untuk
compile & jalan di simulator. Script tidak pernah mencetak nilai secret.

### CI (GitHub Actions)

```bash
python3 scripts/generate_secrets.py --strict
```

`--strict` = fail-fast: bila ada env kosong, script keluar dengan exit code 1
dan pesan `ERROR: <NAMA_VAR> kosong...` **tanpa mencetak nilai secret**.
Workflow `build.yml` dan `screenshot.yml` menjalankan step ini tepat setelah
checkout, dengan secret diteruskan dari GitHub Secrets.

### Tentang obfuskasi

Generator memecah tiap secret jadi 4–6 chunk, tiap chunk di-base64, dan Swift
merakit ulang saat runtime. Ini speed-bump anti-string-scan biasa, **bukan
keamanan 100%** — ekstraktor serius tetap bisa menemukan nilainya.
