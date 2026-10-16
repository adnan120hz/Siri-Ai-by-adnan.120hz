#!/usr/bin/env python3
"""Cetak kode redeem offline format SIRI-XXXX-XXXX.

Penggunaan:
    REDEEM_SECRET=<secret> python3 tools/mint_redeem_code.py --count 10

Secret HANYA dibaca dari env REDEEM_SECRET. Tidak ada arg --secret, tidak ada
hardcode. Setiap kode yang dicetak lolos self-check verify() internal —
kalau ada yang gagal, program berhenti dan tidak mencetak kode yang gagal.
"""

import argparse
import hashlib
import hmac
import os
import secrets
import sys

ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 31 char, tanpa 0/O/1/I/L


def _checksum(payload: str, secret: str) -> str:
    mac = hmac.new(secret.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).digest()
    return "".join(ALPHABET[b % 31] for b in mac[:4])


def mint(secret: str) -> str:
    payload = "".join(secrets.choice(ALPHABET) for _ in range(4))
    return f"SIRI-{payload}-{_checksum(payload, secret)}"


def _constant_time_equal(a: str, b: str) -> bool:
    au, bu = a.encode(), b.encode()
    if len(au) != len(bu):
        return False
    diff = 0
    for x, y in zip(au, bu):
        diff |= x ^ y
    return diff == 0


def verify(code: str, secret: str) -> bool:
    code = code.strip().upper()
    if len(code) != 14:
        return False
    parts = code.split("-")
    if len(parts) != 3 or parts[0] != "SIRI" or len(parts[1]) != 4 or len(parts[2]) != 4:
        return False
    payload, given = parts[1], parts[2]
    if any(c not in ALPHABET for c in payload + given):
        return False
    return _constant_time_equal(given, _checksum(payload, secret))


def main() -> None:
    parser = argparse.ArgumentParser(description="Mint kode redeem offline.")
    parser.add_argument("--count", type=int, default=1, help="Jumlah kode unik yang dicetak.")
    args = parser.parse_args()

    if args.count < 1:
        print("error: --count harus >= 1", file=sys.stderr)
        sys.exit(2)

    secret = os.environ.get("REDEEM_SECRET")
    if not secret:
        print("error: env REDEEM_SECRET kosong. Set dulu, misal:", file=sys.stderr)
        print("  REDEEM_SECRET=$(openssl rand -base64 32) python3 tools/mint_redeem_code.py --count 10",
              file=sys.stderr)
        sys.exit(1)

    issued = set()
    while len(issued) < args.count:
        code = mint(secret)
        # Self-check: setiap kode yang dicetak WAJIB lolos verify internal.
        if not verify(code, secret):
            print(f"error: self-check gagal untuk {code}", file=sys.stderr)
            sys.exit(3)
        if code in issued:
            continue
        issued.add(code)
        print(code)


if __name__ == "__main__":
    main()
