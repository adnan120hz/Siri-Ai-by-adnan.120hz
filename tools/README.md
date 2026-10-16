# tools

## Redeem code (SIRI-XXXX-XXXX)

### 1. Generate secret kuat

```sh
openssl rand -base64 32
```

Simpan output-nya sebagai GitHub Secret `REDEEM_SECRET` (repo Settings →
Secrets and variables → Actions → New repository secret). Secret juga diinject
ke app saat build via `scripts/generate_secrets.py` menjadi `Secrets.redeemSecret`.
**Jangan pernah commit nilai secret ke repo.**

### 2. Mint kode redeem

```sh
REDEEM_SECRET="<secret>" python3 tools/mint_redeem_code.py --count 10
```

- Secret **hanya** dibaca dari env `REDEEM_SECRET`. Tidak ada arg `--secret`,
  tidak ada hardcode.
- Setiap kode yang dicetak sudah lolos self-check `verify()` internal;
  program berhenti (exit 3) bila ada kode yang gagal verifikasi.
- Kode yang dicetak dijamin unik dalam satu run.

Bagikan kode ke pembeli lewat channel manual (mis. WhatsApp).

### 3. Verifikasi silang Swift ↔ Python

Skema (harus cocok byte-per-byte di `AiAdnan120hz/AiAdnan120hz/RedeemValidator.swift`
dan `tools/mint_redeem_code.py`):

- Alphabet: `ABCDEFGHJKMNPQRSTUVWXYZ23456789` (31 char, tanpa 0/O/1/I/L)
- Checksum = 4 char: `alphabet[ HMAC-SHA256(key: secret, data: payload)[i] % len(alphabet) ]`, i=0..<4
- Format: `SIRI-<payload4>-<checksum4>`
- Normalisasi input (identik di Swift & Python): buang SEMUA whitespace,
  jadikan huruf besar — jadi `  siri-abcd-kska\n` dan `SIRI-AB CD-KSKA`
  tetap diterima. Bandingkan checksum dengan compare constant-time
  (`hmac.compare_digest` di Python, loop XOR di Swift).

**Test vector:**

| secret | payload | kode yang diharapkan |
|--------|---------|----------------------|
| `TEST` | `ABCD`  | `SIRI-ABCD-KSKA`     |

Hitungan manual dari digest `47 8b 47 5d …`:

- `0x47`=71, 71 % 31 = 9  → alphabet[9]  = `K`
- `0x8b`=139, 139 % 31 = 15 → alphabet[15] = `S`
- `0x47`=71  → `K`
- `0x5d`=93, 93 % 31 = 0  → alphabet[0]  = `A`

Cek di Python (jalankan dari folder `tools/` agar modul ketemu):

```sh
cd tools
REDEEM_SECRET=TEST python3 -c "
from mint_redeem_code import verify
print(verify('SIRI-ABCD-KSKA', 'TEST'))  # harus True
print(verify('  siri-abcd-kska', 'TEST'))  # harus True (normalize)
"
```

Cek di Swift (mis. dari unit test / debug): `RedeemValidator.validate("SIRI-ABCD-KSKA", secret: Secrets.redeemSecret)` harus `true` bila `Secrets.redeemSecret == "TEST"`.

> **Catatan jujur:** validasi offline hanyalah speed-bump. Secret tertanam di
> binary dan logika ini bisa di-reverse-engineer dari IPA. Ini gesekan UX
> untuk distribusi kode manual, bukan pertahanan anti-tamper.
