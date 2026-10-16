#!/usr/bin/env python3
"""Generate Secrets.swift dari environment variables.

Cara pakai:
    python3 scripts/generate_secrets.py            # lokal: env kosong -> dummy
    python3 scripts/generate_secrets.py --strict   # CI: env kosong -> exit 1

Environment variables yang dibaca:
    GEMINI_API_KEY_FREE
    GEMINI_API_KEY_PREMIUM
    REDEEM_SECRET

ATURAN: script ini TIDAK PERNAH mencetak nilai secret ke stdout/log.
"""

import argparse
import base64
import os
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_PATH = os.path.join(
    REPO_ROOT, "AiAdnan120hz", "AiAdnan120hz", "Secrets.swift"
)

# (nama env, nama properti Swift, nilai dummy lokal)
SECRETS = [
    ("GEMINI_API_KEY_FREE", "geminiFreeKey", "DUMMY_FREE_KEY"),
    ("GEMINI_API_KEY_PREMIUM", "geminiPremiumKey", "DUMMY_PREMIUM_KEY"),
    ("REDEEM_SECRET", "redeemSecret", "DUMMY_REDEEM_SECRET"),
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Generate Secrets.swift dari env (obfuskasi best-effort)."
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="Fail-fast bila ada env yang kosong (untuk CI).",
    )
    return p.parse_args()


def split_into_chunks(secret: str) -> list:
    """Pecah secret jadi 4-6 chunk (deterministik), tiap chunk di-base64."""
    raw = secret.encode("utf-8")
    n = 4 + (len(raw) % 3)  # 4, 5, atau 6 chunk
    # Bagi rata; sisa dibagikan ke chunk-chunk awal.
    size, rem = divmod(len(raw), n)
    chunks = []
    start = 0
    for i in range(n):
        end = start + size + (1 if i < rem else 0)
        chunks.append(base64.b64encode(raw[start:end]).decode("ascii"))
        start = end
    return chunks


def swift_property(prop_name: str, chunks: list) -> str:
    parts = ",\n        ".join(f'"{c}"' for c in chunks)
    return (
        f"    static let {prop_name}: String = decode([\n"
        f"        {parts},\n"
        f"    ])"
    )


def main() -> int:
    args = parse_args()
    values = {}
    for env_name, prop_name, dummy in SECRETS:
        value = os.environ.get(env_name, "").strip()
        if not value:
            if args.strict:
                print(
                    f"ERROR: {env_name} kosong. Set GitHub Secret "
                    f"'{env_name}' sebelum menjalankan build.",
                    file=sys.stderr,
                )
                return 1
            print(
                f"INFO: {env_name} tidak diset -> pakai dummy "
                f"untuk {prop_name} (mode lokal)."
            )
            value = dummy
        values[prop_name] = value

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    properties = "\n\n".join(
        swift_property(prop, split_into_chunks(values[prop]))
        for _, prop, _ in SECRETS
    )

    content = f"""// Secrets.swift — FILE INI DI-GENERATE OTOMATIS, JANGAN EDIT MANUAL.
// Dibuat oleh: scripts/generate_secrets.py pada {stamp}.
// File ini masuk .gitignore dan TIDAK BOLEH di-commit ke git.
//
// JUJUR SOAL OBFUSKASI: secret di bawah dipecah jadi beberapa chunk lalu
// di-base64 agar tidak langsung terbaca di binary. Ini hanya speed-bump —
// ekstraktor serius tetap bisa menemukan nilainya. Ini BUKAN keamanan 100%.

import Foundation

enum Secrets {{
    private static func decode(_ parts: [String]) -> String {{
        var data = Data()
        for part in parts {{
            guard let chunk = Data(base64Encoded: part) else {{ continue }}
            data.append(chunk)
        }}
        return String(data: data, encoding: .utf8) ?? ""
    }}

{properties}
}}
"""

    os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"OK: Secrets.swift ditulis ke {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
