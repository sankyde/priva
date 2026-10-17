#!/usr/bin/env python3
"""Moderation for Priva's directory (docs/MODERATION.md).

The server never stores usernames, only a one-way commitment. This computes a username's commitment exactly as the
app does (UsernameKey.derive: scrypt N=2^16 r=8 p=1 → HKDF-SHA512 "priva/ucommit") and prints the SQL to run in the
Supabase SQL editor.

    scripts/moderate.py commit  <username>   # just the commitment (hex)
    scripts/moderate.py remove  <username>   # SQL: remove from the directory and refuse re-registration
    scripts/moderate.py restore <username>   # SQL: undo a removal made in error (the user registers again)
"""
import hashlib
import hmac
import sys


def normalize(name: str) -> str:
    s = name.strip().lower().replace("@", "")
    for c in " -.":
        s = s.replace(c, "_")
    return s


def hkdf_sha512(ikm: bytes, info: bytes, length: int) -> bytes:
    prk = hmac.new(b"\x00" * 64, ikm, hashlib.sha512).digest()   # empty salt = HashLen zeros (RFC 5869)
    okm, t, i = b"", b"", 1
    while len(okm) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha512).digest()
        okm += t
        i += 1
    return okm[:length]


def commitment(username: str) -> str:
    name = normalize(username)
    stretched = hashlib.scrypt(("priva-username-v1|" + name).encode(), salt=b"priva.directory.v1",
                               n=1 << 16, r=8, p=1, maxmem=160 * 1024 * 1024, dklen=64)
    return hkdf_sha512(stretched, b"priva/ucommit", 32).hex()


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in ("commit", "remove", "restore"):
        sys.exit(__doc__)
    action, username = sys.argv[1], sys.argv[2]
    c = commitment(username)
    if action == "commit":
        print(c)
    elif action == "remove":
        print(f"-- Remove @{normalize(username)} from Priva's directory and refuse the name from now on.\n"
              f"begin;\n"
              f"insert into priva.retired_commits (ucommit) values ('{c}') on conflict do nothing;\n"
              f"delete from priva.directory where ucommit = '{c}';\n"
              f"commit;")
    else:
        print(f"-- Allow @{normalize(username)} to be registered again.\n"
              f"delete from priva.retired_commits where ucommit = '{c}';")


if __name__ == "__main__":
    main()
