#!/usr/bin/env python3
"""OmacVM's release keys on the Mac's command line (docs/release-keys.md).

  keys.py verify KIND FILE         FILE.sig by a trusted release key, FILE of KIND
                                   (app-feed, control-manifest, prebuilt-manifest)
                                   with 1 to 4 devid_teams: exit 0, else 1 and why
  keys.py app-feed FILE VERSION    OmacVM.app's feed of release VERSION, checked:
                                   prints "SHA256 LENGTH TEAM..." (src/lib/app.sh)
  keys.py release-check FILE       for the release scripts: FILE.sig by a key the
                                   apps ship (src/lib/release-key*.pub only)

Trusted: the main and the spare key in src/lib (either one), plus a spare a
trusted document named ("next_spare_key"), kept as that document and its
signature in ~/Library/Application Support/omacvm/release-keys (the folder
OmacVM.app and the Bridge use, see ReleaseKeys.swift), minus the keys a
document signed by a shipped key revoked ("revoked_keys", kept the same
way). Nothing of a document is used before its signature checks out.

Tests: OMACVM_RELEASE_TEST_KEYS (public keys, space-separated) instead of
the shipped ones; ignored when this copy lies inside OmacVM.app
(org.omacvm.app), whose files the user cannot change. OMACVM_SETTINGS_DIR:
the kept documents' parent folder.

Ed25519 verification below is RFC 8032's reference algorithm (section 5.1.7,
cofactorless, S < L checked): macOS's python3 has no Ed25519 and its
LibreSSL none either. Verification only; signing stays with
src/release/sign.swift (CryptoKit). Runs with macOS's python3 3.9.
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import plistlib
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
KINDS = ("app-feed", "control-manifest", "prebuilt-manifest")
MAX_DOC = 256 * 1024
MAX_KEPT = 8        # documents used from the folder
MAX_SCAN = 256      # files looked at there
MAX_REVOKED = 8
TEAM = re.compile(r"[A-Z0-9]{10}")

# ---- Ed25519 verification (RFC 8032) ----
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _add(a, b):
    A = (a[1] - a[0]) * (b[1] - b[0]) % _P
    B = (a[1] + a[0]) * (b[1] + b[0]) % _P
    C = 2 * a[3] * b[3] * _D % _P
    D = 2 * a[2] * b[2] % _P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % _P, G * H % _P, F * G % _P, E * H % _P)


def _mul(s, pt):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, pt)
        pt = _add(pt, pt)
        s >>= 1
    return q


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % _P == 0 and (a[1] * b[2] - b[1] * a[2]) % _P == 0


def _x(y, sign):
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P:
        x = x * _I % _P
    if (x * x - x2) % _P:
        return None
    if x & 1 != sign:
        x = _P - x
    return x


def _point(b):
    if len(b) != 32:
        return None
    y = int.from_bytes(b, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    x = _x(y, sign)
    return None if x is None else (x, y, 1, x * y % _P)


_GY = 4 * pow(5, _P - 2, _P) % _P
_G = (_x(_GY, 0), _GY, 1, _x(_GY, 0) * _GY % _P)


def ed25519_verify(public: bytes, msg: bytes, sig: bytes) -> bool:
    if len(public) != 32 or len(sig) != 64:
        return False
    a, r = _point(public), _point(sig[:32])
    s = int.from_bytes(sig[32:], "little")
    if a is None or r is None or s >= _L:
        return False
    h = int.from_bytes(hashlib.sha512(sig[:32] + public + msg).digest(), "little") % _L
    return _equal(_mul(s, _G), _add(r, _mul(h, a)))


# ---- keys ----
def key(text) -> bytes | None:
    """Raw 32 bytes from base64 text, or None (also for a point off the curve)."""
    if not isinstance(text, str):
        return None
    try:
        k = base64.b64decode(text.strip(), validate=True)
    except (binascii.Error, ValueError):
        return None
    return k if len(k) == 32 and _point(k) is not None else None


def _in_release_app() -> bool:
    """This copy of src/ lies in OmacVM.app (Contents/Resources/omacvm/src)."""
    parts = os.path.realpath(SRC).split(os.sep)
    if parts[-4:-1] != ["Contents", "Resources", "omacvm"]:
        return False
    try:
        with open(os.sep.join(parts[:-3] + ["Info.plist"]), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier") == "org.omacvm.app"
    except (OSError, ValueError, plistlib.InvalidFileException):
        return True   # unreadable: no test hooks


def shipped(hooks: bool = True) -> list:
    t = os.environ.get("OMACVM_RELEASE_TEST_KEYS", "")
    if hooks and t and not _in_release_app():
        return [k for k in map(key, t.split()) if k]
    out = []
    for name in ("release-key.pub", "release-key-spare.pub"):
        try:
            with open(os.path.join(SRC, "lib", name), encoding="ascii") as f:
                k = key(f.read())
        except (OSError, UnicodeDecodeError):
            k = None
        if k:
            out.append(k)
    return out


def store() -> str:
    base = os.environ.get("OMACVM_SETTINGS_DIR") or os.path.expanduser("~/Library/Application Support/omacvm")
    return os.path.join(base, "release-keys")


def _sig(raw: bytes) -> bytes | None:
    try:
        s = base64.b64decode(raw.decode("ascii").strip(), validate=True)
    except (binascii.Error, ValueError, UnicodeDecodeError):
        return None
    return s if len(s) == 64 else None


def signed(data: bytes, sig_raw: bytes, keys: list) -> bool:
    s = _sig(sig_raw)
    return s is not None and any(ed25519_verify(k, data, s) for k in keys)


def revoked_keys(v) -> list | None:
    """"revoked_keys": 1 to MAX_REVOKED distinct keys, else None."""
    if not isinstance(v, list) or not 1 <= len(v) <= MAX_REVOKED:
        return None
    out = [key(x) for x in v]
    return out if all(out) and len(set(out)) == len(out) else None


def _doc(data: bytes, sig: bytes):
    """A document that may change the trusted keys: (data, sig, the key it
    names or None, the keys it revokes). None for anything else."""
    if len(data) > MAX_DOC or len(sig) > 1024 or _sig(sig) is None:
        return None
    try:
        o = json.loads(data)
    except ValueError:
        return None
    if not isinstance(o, dict) or o.get("kind") not in KINDS:
        return None
    named, revokes = key(o.get("next_spare_key")), revoked_keys(o.get("revoked_keys")) or []
    return (data, sig, named, revokes) if named or revokes else None


def _resolve(keys: list, docs: list):
    """The trusted keys, the revoked keys and the documents used (indexes).
    Revocations count only when a shipped key signed them, and never revoke
    a shipped key (a release drops one by not shipping it), so a leaked
    named spare cannot revoke the keys that would replace it. A revocation
    is used once per shipped key that signs it, so it still holds after a
    release stops shipping one of them. Then the named spares, each signed
    by a trusted key that is not revoked: what a revoked key signed (and the
    chain after it) is not trusted. At most MAX_KEPT documents are used; a
    document that does not verify uses none."""
    shipped = list(dict.fromkeys(keys))
    revoked, used, by = set(), [], {}
    for i, (data, sig, _, revokes) in enumerate(docs):
        signer = next((k for k in shipped if signed(data, sig, [k])), None) if revokes and len(used) < MAX_KEPT else None
        new = set(revokes) - set(shipped) - by.get(signer, set()) if signer else set()
        if new:
            by.setdefault(signer, set()).update(new)
            revoked |= new
            used.append(i)
    trusted, fresh = list(shipped), list(shipped)
    left = [i for i, d in enumerate(docs) if d[2]]
    # Each document is checked once against each key, as the key comes in.
    while fresh and left:
        added = []
        for i in list(left):
            data, sig, named, _ = docs[i]
            if not signed(data, sig, fresh):
                continue
            left.remove(i)
            if named in revoked or named in trusted or (i not in used and len(used) >= MAX_KEPT):
                continue
            trusted.append(named)
            added.append(named)
            if i not in used:
                used.append(i)
        fresh = added
    return trusted, revoked, used


def _kept() -> list:
    """The documents in the folder that could matter (at most MAX_SCAN files
    looked at; junk is skipped and counts toward nothing)."""
    d = store()
    try:
        names = sorted(n for n in os.listdir(d) if re.fullmatch(r"[0-9a-f]{16}\.json", n))[:MAX_SCAN]
    except OSError:
        return []
    out = []
    for n in names:
        try:
            with open(os.path.join(d, n), "rb") as f:
                data = f.read(MAX_DOC + 1)
            with open(os.path.join(d, n + ".sig"), "rb") as f:
                sig = f.read(1025)
        except OSError:
            continue
        doc = _doc(data, sig)
        if doc:
            out.append(doc)
    return out


def trusted(hooks: bool = True) -> list:
    return _resolve(shipped(hooks), _kept())[0]


def remember(data: bytes, sig: bytes) -> bool:
    """Keeps a verified document that names a key not trusted yet or revokes
    one not revoked yet (and that fits under MAX_KEPT)."""
    doc = _doc(data, sig)
    if not doc:
        return False
    keys, kept = shipped(), _kept()
    before, after = _resolve(keys, kept), _resolve(keys, kept + [doc])
    if len(kept) not in after[2] or (set(after[0]) <= set(before[0]) and after[1] <= before[1] and not doc[3]):
        return False
    d = store()
    name = hashlib.sha256(data + sig).hexdigest()[:16]   # one file per signer
    try:
        os.makedirs(d, exist_ok=True)
        for suffix, content in ((".json.sig", sig), (".json", data)):
            tmp = os.path.join(d, ".%s%s.tmp" % (name, suffix))
            with open(tmp, "wb") as f:
                f.write(content)
            os.replace(tmp, os.path.join(d, name + suffix))
    except OSError:
        return False
    return True


class Refused(ValueError):
    pass


def teams(v) -> list:
    if not isinstance(v, list) or not 1 <= len(v) <= 4:
        raise Refused("no Developer ID teams (devid_teams)")
    if not all(isinstance(t, str) and TEAM.fullmatch(t) for t in v) or len(set(v)) != len(v):
        raise Refused("bad devid_teams")
    return v


def load_bytes(data: bytes, sig: bytes, kind: str) -> dict:
    """The document as a dict once its signature and kind check out."""
    if len(data) > MAX_DOC or len(sig) > 1024:
        raise Refused("too large")
    keys = trusted()
    if not keys:
        raise Refused("no release key")
    if not signed(data, sig, keys):
        raise Refused("the signature does not match OmacVM's release keys")
    try:
        o = json.loads(data)
    except ValueError:
        raise Refused("not JSON")
    if not isinstance(o, dict) or o.get("kind") != kind:
        raise Refused("not a %s" % kind)
    teams(o.get("devid_teams"))
    if "next_spare_key" in o and not key(o["next_spare_key"]):
        raise Refused("bad next_spare_key")
    if "revoked_keys" in o and not revoked_keys(o["revoked_keys"]):
        raise Refused("bad revoked_keys")
    remember(data, sig)
    return o


def load(path: str, kind: str) -> dict:
    """PATH with PATH.sig next to it."""
    try:
        with open(path, "rb") as f:
            data = f.read(MAX_DOC + 1)
        with open(path + ".sig", "rb") as f:
            sig = f.read(1025)
    except OSError as e:
        raise Refused("%s: %s" % (os.path.basename(e.filename or path), e.strerror))
    return load_bytes(data, sig, kind)


VERSION = re.compile(r"[0-9]{1,4}(\.[0-9]{1,4}){1,3}")


def app_feed(path: str, version: str) -> str:
    o = load(path, "app-feed")
    if o.get("schema") != 1 or o.get("version") != version or not VERSION.fullmatch(version):
        raise Refused("the feed is not for OmacVM.app %s" % version)
    sha, length = o.get("sha256"), o.get("length")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise Refused("bad sha256")
    if type(length) is not int or not 0 < length <= 2 << 30:
        raise Refused("bad length")
    return " ".join([sha, str(length)] + o["devid_teams"])


def main(a: list) -> int:
    try:
        if len(a) == 4 and a[1] == "verify" and a[2] in KINDS:
            load(a[3], a[2])
        elif len(a) == 4 and a[1] == "app-feed":
            print(app_feed(a[2], a[3]))
        elif len(a) == 3 and a[1] == "release-check":
            with open(a[2], "rb") as f, open(a[2] + ".sig", "rb") as g:
                if not signed(f.read(), g.read(1025), shipped(hooks=False)):
                    raise Refused("not signed by a key in src/lib/release-key.pub or release-key-spare.pub")
        else:
            print(__doc__.split("\n\n")[1], file=sys.stderr)
            return 2
    except (Refused, OSError) as e:
        print("keys.py: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
