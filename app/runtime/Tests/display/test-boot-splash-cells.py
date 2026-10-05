#!/usr/bin/env python3
"""The boot splash (omacvm-cocoa-boot-splash.patch) draws the firmware's logo,
cell for cell and as big: the cells in ui/omacvm-splash.h, made into a BMP
with its SPLASH_CELL the way boot-logo/make-logo-bmp.py makes the firmware's,
must give the very bytes edk2-logo-omarchy.patch puts into
MdeModulePkg/Logo/Logo.bmp (its git blob id).

  test-boot-splash-cells.py ui/omacvm-splash.h
"""
import hashlib
import importlib.util
import os
import re
import sys

sys.dont_write_bytecode = True   # no __pycache__ in the checkout
here = os.path.dirname(os.path.abspath(__file__))
runtime = os.path.normpath(os.path.join(here, "..", ".."))

spec = importlib.util.spec_from_file_location(
    "make_logo_bmp", os.path.join(runtime, "boot-logo", "make-logo-bmp.py"))
logo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logo)


def fail(msg):
    print("test-boot-splash-cells: " + msg, file=sys.stderr)
    sys.exit(1)


src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"omacvm_splash_cells\[SPLASH_ROWS\]\[SPLASH_COLS \+ 1\] = \{(.*?)\};", src, re.S)
if not m:
    fail("no omacvm_splash_cells in " + sys.argv[1])
rows = re.findall(r'"([#.]+)"', m.group(1))
if len(rows) != 19 or any(len(r) != 81 for r in rows):
    fail("the cells are not 81 x 19")

m = re.search(r"^#define SPLASH_CELL (\d+)", src, re.M)
if not m:
    fail("no SPLASH_CELL in " + sys.argv[1])
data = logo.bmp([[c == "#" for c in r] for r in rows], int(m.group(1)))
blob = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()

patch = open(os.path.join(runtime, "patches", "edk2-logo-omarchy.patch"), encoding="utf-8").read()
m = re.search(r"^index [0-9a-f]+\.\.([0-9a-f]{40})", patch, re.M)
if not m:
    fail("no Logo.bmp blob id in edk2-logo-omarchy.patch")
if blob != m.group(1):
    fail("the splash cells differ from the firmware's logo (%s, firmware %s)" % (blob, m.group(1)))
print("test-boot-splash-cells: the splash is the firmware's logo (%s)" % blob)
