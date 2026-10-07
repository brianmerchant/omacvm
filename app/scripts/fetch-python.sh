#!/bin/bash
# The python3 OmacVM.app carries (Contents/Resources/python), so the app's
# scripts and its omacvm run on a Mac without Xcode's Command Line Tools,
# where /usr/bin/python3 only asks to install them (src/lib/tools.sh). CPython
# as built by python-build-standalone (one static binary, its standard
# library beside it), pinned by release and SHA-256, cut to what OmacVM's Mac
# side uses: no tests, IDLE, Tk, pip or extension modules. About 25 MB, 10 MB
# in the zip. Downloaded once into app/.build (build-app.sh runs this).
#   scripts/fetch-python.sh     prints the folder to copy (bin/python3 inside)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PY_RELEASE=20261003
PY_VERSION=3.13.16
PY_SHA256=9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147
NAME=cpython-$PY_VERSION+$PY_RELEASE-aarch64-apple-darwin-install_only_stripped.tar.gz
URL=https://github.com/astral-sh/python-build-standalone/releases/download/$PY_RELEASE/$NAME
OUT=$ROOT/.build/python-$PY_VERSION-$PY_RELEASE
PY=$OUT/python

# The modules OmacVM's Mac side imports (src/prebuilt, src/release, the
# control centre's report, src/lib); a cut that took one away fails here.
smoke() {
  PYTHONDONTWRITEBYTECODE=1 "$PY/bin/python3" -I -c '
import argparse, base64, binascii, dataclasses, datetime, fnmatch, getpass, hashlib, json, os, platform
import plistlib, pwd, random, re, secrets, socket, stat, struct, subprocess, sys, unicodedata, urllib.parse
import uuid, xml.etree.ElementTree
assert hashlib.sha512(b"").hexdigest().startswith("cf83e135")
print("ok")'
}

if [[ -x $PY/bin/python3 && $(smoke 2>/dev/null) == ok ]]; then echo "$PY"; exit 0; fi
rm -rf "$OUT"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
echo "==> python $PY_VERSION ($PY_RELEASE, python-build-standalone)" >&2
curl -fsSL --retry 3 -o "$T/py.tgz" "$URL"
[[ $(shasum -a 256 "$T/py.tgz" | cut -d' ' -f1) == "$PY_SHA256" ]] || { echo "$NAME is not the pinned one" >&2; exit 1; }
mkdir "$T/x"
tar -xzf "$T/py.tgz" -C "$T/x"
mkdir -p "$OUT/python/bin" "$OUT/python/lib"
# The interpreter is one static binary; the rest of bin/ and lib/ (Tcl/Tk,
# libpython for embedding, headers) is not needed.
install -m755 "$T/x/python/bin/python3.13" "$OUT/python/bin/python3.13"
ln -s python3.13 "$OUT/python/bin/python3"
cp -R "$T/x/python/lib/python3.13" "$OUT/python/lib/"
L=$OUT/python/lib/python3.13
rm -rf "$L/test" "$L/idlelib" "$L/tkinter" "$L/turtledemo" "$L/turtle.py" "$L/ensurepip" \
  "$L/pydoc_data" "$L/venv" "$L/__phello__" "$L/config-3.13-darwin" "$L"/site-packages/*
# Only _tkinter and _dbm are extension modules here; an empty folder keeps
# Python from warning that it is missing.
rm -rf "$L/lib-dynload"; mkdir "$L/lib-dynload"
cp "$L/LICENSE.txt" "$OUT/LICENSE.python.txt"
[[ $(smoke) == ok ]] || { echo "the cut python does not run OmacVM's imports" >&2; exit 1; }
echo "$PY"
