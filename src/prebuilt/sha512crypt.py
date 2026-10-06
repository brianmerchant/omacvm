#!/usr/bin/env python3
"""A password hash for /etc/shadow ($6$, SHA-512 crypt), as `openssl passwd -6`.

  printf '%s' PASSWORD | sha512crypt.py [--salt SALT]

macOS's openssl (LibreSSL) has no -6 and OmacVM.app needs no Homebrew, so its
prebuilt route hashes here. The algorithm is Ulrich Drepper's "Unix crypt
using SHA-256 and SHA-512" (glibc's), with the default 5000 rounds.
"""
import hashlib
import secrets
import sys

ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
# The order the 64 digest bytes are written in, three at a time.
ORDER = [(0, 21, 42), (22, 43, 1), (44, 2, 23), (3, 24, 45), (25, 46, 4), (47, 5, 26), (6, 27, 48),
         (28, 49, 7), (50, 8, 29), (9, 30, 51), (31, 52, 10), (53, 11, 32), (12, 33, 54), (34, 55, 13),
         (56, 14, 35), (15, 36, 57), (37, 58, 16), (59, 17, 38), (18, 39, 60), (40, 61, 19), (62, 20, 41)]


def repeat(digest, n):
    return (digest * (n // 64 + 1))[:n]


def sha512_crypt(password, salt, rounds=5000):
    p, s = password, salt.encode()[:16]
    b = hashlib.sha512(p + s + p).digest()
    a = hashlib.sha512(p + s)
    a.update(repeat(b, len(p)))
    n = len(p)
    while n:
        a.update(b if n & 1 else p)
        n >>= 1
    a = a.digest()
    ps = repeat(hashlib.sha512(p * len(p)).digest(), len(p))
    ss = repeat(hashlib.sha512(s * (16 + a[0])).digest(), len(s))
    c = a
    for i in range(rounds):
        h = hashlib.sha512(ps if i & 1 else c)
        if i % 3:
            h.update(ss)
        if i % 7:
            h.update(ps)
        h.update(c if i & 1 else ps)
        c = h.digest()
    out = []
    for i, j, k in ORDER + [(None, None, 63)]:
        w = (c[i] << 16 if i is not None else 0) | (c[j] << 8 if j is not None else 0) | c[k]
        for _ in range(4 if i is not None else 2):
            out.append(ITOA64[w & 63])
            w >>= 6
    return "$6$%s$%s" % (s.decode(), "".join(out))


def main(a):
    salt = None
    if len(a) == 3 and a[1] == "--salt":
        salt = a[2]
    elif len(a) != 1:
        sys.exit(__doc__)
    if salt is None:
        salt = "".join(secrets.choice(ITOA64) for _ in range(16))
    if not salt or any(ch not in ITOA64 for ch in salt):
        sys.exit("sha512crypt.py: the salt takes ./0-9A-Za-z only")
    pw = sys.stdin.buffer.read()
    if not pw or b"\n" in pw or b"\0" in pw:
        sys.exit("sha512crypt.py: one password on stdin, without a newline")
    print(sha512_crypt(pw, salt))


if __name__ == "__main__":
    main(sys.argv)
