"""Textual and what it needs, shipped with OmacVM: the pure-Python wheels in
src/control/vendor (pinned, checked against SHA256SUMS there), so the control
centre needs nothing from pacman. Until 3.0.6 it came from python-textual
through pacman, which fails on a VM whose package list is older than the
mirrors (a 404 for every file, 2026-10-08): the control centre stayed plain
text on every VM not updated for a few days.

The wheels go unpacked into the desktop user's cache once per set (the folder
is named by their hash), where Python keeps its compiled files: about 0.1 s
to load instead of 0.5 s from the zip files. Standard library only, and no
imports from omacvm_cc: guest/install.sh and check.sh run this file alone.

  python3 vendor.py           unpack (if needed), print the folder
  python3 vendor.py --check   the wheels as shipped, Textual loads from them
                              (nothing written; check.sh as root)"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

CONTROL = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
DONE = ".omacvm-complete"   # in a finished folder; its time says when it was last used
KEEP_OLD = 7 * 86400


def vendor_dir() -> str:
    # OMACVM_VENDOR_DIR: the tests point it elsewhere (or at nothing).
    return os.environ.get("OMACVM_VENDOR_DIR") or os.path.join(CONTROL, "vendor")


def cache_root() -> str:
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "omacvm", "python")


class Missing(Exception):
    """The shipped wheels are not there or not as shipped (the message says which)."""


def wheels(d: str | None = None) -> tuple[list[tuple[str, str]], str]:
    """[(file, sha256)] from SHA256SUMS, and the set's id (its hash). Only
    plain *.whl names in that folder."""
    d = d or vendor_dir()
    try:
        with open(os.path.join(d, "SHA256SUMS"), "rb") as f:
            text = f.read()
    except OSError:
        raise Missing(f"OmacVM's copy of Textual is missing ({d})") from None
    out = []
    for line in text.decode("ascii", "replace").splitlines():
        parts = line.split()
        if not parts:
            continue
        if len(parts) != 2 or len(parts[0]) != 64 or not parts[1].endswith(".whl") or "/" in parts[1] \
                or parts[1].startswith("."):
            raise Missing(f"OmacVM's copy of Textual: a bad line in {d}/SHA256SUMS")
        out.append((parts[1], parts[0].lower()))
    if not out:
        raise Missing(f"OmacVM's copy of Textual: {d}/SHA256SUMS lists nothing")
    return out, hashlib.sha256(text).hexdigest()[:16]


def verify(d: str | None = None) -> list[str]:
    """The wheels' paths once each matches its sum (Missing otherwise)."""
    d = d or vendor_dir()
    listed, _ = wheels(d)
    paths = []
    for name, want in listed:
        p = os.path.join(d, name)
        h = hashlib.sha256()
        try:
            with open(p, "rb") as f:
                for block in iter(lambda: f.read(1 << 20), b""):
                    h.update(block)
        except OSError:
            raise Missing(f"OmacVM's copy of Textual: {name} is missing") from None
        if h.hexdigest() != want:
            raise Missing(f"OmacVM's copy of Textual: {name} is not as shipped (copy OmacVM into the VM again)")
        paths.append(p)
    return paths


def _unpack(paths: list[str], into: str) -> None:
    root = os.path.realpath(into)
    for p in paths:
        with zipfile.ZipFile(p) as z:
            for m in z.infolist():
                # Only names inside the folder (a wheel is a zip file: never trust a path in it).
                dest = os.path.realpath(os.path.join(root, m.filename))
                if not dest.startswith(root + os.sep):
                    raise Missing(f"OmacVM's copy of Textual: {os.path.basename(p)} has a bad path")
            z.extractall(root)


def ensure() -> str:
    """The folder with Textual unpacked (made once per set of wheels); old
    sets go. Missing (with the reason) when it cannot be."""
    _, sid = wheels()
    root = cache_root()
    target = os.path.join(root, sid)
    if os.path.exists(os.path.join(target, DONE)):
        _used(target)
        return target
    paths = verify()
    try:
        os.makedirs(root, exist_ok=True)
        tmp = tempfile.mkdtemp(prefix=".new-", dir=root)
    except OSError as e:
        raise Missing(f"OmacVM's copy of Textual could not be unpacked in {root}: {e.strerror or e}") from None
    try:
        _unpack(paths, tmp)
        open(os.path.join(tmp, DONE), "w").close()
        if not os.path.exists(os.path.join(target, DONE)):   # else another start was quicker
            if os.path.isdir(target):   # an unfinished one: replaced
                shutil.rmtree(target, ignore_errors=True)
            try:
                os.rename(tmp, target)
            except OSError:
                if not os.path.exists(os.path.join(target, DONE)):
                    raise
    except OSError as e:
        raise Missing(f"OmacVM's copy of Textual could not be unpacked in {root}: {e.strerror or e}") from None
    finally:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
    # The sets of older OmacVM versions, once unused for a week (a control
    # centre that ran the update still runs on its own set; not another
    # start's unfinished one either).
    for old in os.listdir(root):
        mark = os.path.join(root, old, DONE)
        try:
            unused = time.time() - os.stat(mark).st_mtime > KEEP_OLD
        except OSError:
            unused = False
        if old != sid and not old.startswith(".") and unused:
            shutil.rmtree(os.path.join(root, old), ignore_errors=True)
    return target


def _used(target: str) -> None:
    try:
        os.utime(os.path.join(target, DONE))
    except OSError:
        pass


def use() -> str:
    """Puts OmacVM's Textual first on sys.path: "" when it is there, else why
    not (then whatever Python finds, if anything, is used)."""
    try:
        path = ensure()
    except Missing as e:
        return str(e)
    if path not in sys.path:
        sys.path.insert(0, path)
    return ""


def check() -> tuple[bool, str]:
    """For check.sh (root, nothing written): the wheels as shipped, and
    Textual loads from them in a separate Python."""
    try:
        paths = verify()
    except Missing as e:
        return False, str(e)
    code = ("import sys; sys.path[:0] = sys.argv[1:]; import textual, textual.app, textual.widgets; "
            "print(textual.__version__)")
    r = subprocess.run([sys.executable, "-I", "-c", code] + paths, capture_output=True, text=True)
    if r.returncode != 0:
        last = (r.stderr.strip().splitlines() or ["it did not load"])[-1]
        return False, f"OmacVM's copy of Textual does not load with Python {sys.version.split()[0]}: {last[:160]}"
    return True, f"{r.stdout.strip()} (OmacVM's own)"


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        ok, text = check()
        print(text)
        sys.exit(0 if ok else 1)
    try:
        print(ensure())
    except Missing as e:
        print(e, file=sys.stderr)
        sys.exit(1)
