#!/bin/bash
# The Mac side of src/tests/e2e/stale-frames (#167): frames.swift reads the
# guest's scanout as scanout-read writes it (XR24 rows with a pitch: B G R X)
# and finds the pixels that changed below the bar. No VM, no window.
#   src/tests/stale-frames-diff.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
swiftc -O "$R/src/tests/e2e/stale-frames/frames.swift" -o "$T/frames" 2>"$T/build.log" || { cat "$T/build.log"; echo "FAIL frames.swift builds"; exit 1; }
fail=0
expect() { if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi; }
# 8x6 pixels, pitch 40 bytes (8 bytes of row padding, as GBM pads rows)
/usr/bin/python3 - "$T" <<'PY'
import sys
t = sys.argv[1]
W, H, P = 8, 6, 40
def frame(changes):
    b = bytearray(P * H)
    for y in range(H):
        for x in range(W):
            b[y*P + x*4: y*P + x*4 + 4] = bytes([0x30, 0x20, 0x10, 0xff])   # B G R X
    for (x, y, bgr) in changes:
        b[y*P + x*4: y*P + x*4 + 3] = bytes(bgr)
    for y in range(H):
        b[y*P + W*4: (y+1)*P] = bytes([0xaa]) * (P - W*4)                # padding differs: ignored
    return b
open(f"{t}/a.raw", "wb").write(frame([]))
open(f"{t}/same.raw", "wb").write(frame([]))
open(f"{t}/border.raw", "wb").write(frame([(2, 3, (0xf7, 0xa2, 0x7a)), (5, 4, (0xf7, 0xa2, 0x7a))]))
open(f"{t}/bar.raw", "wb").write(frame([(1, 0, (0, 0, 0))]))
open(f"{t}/near.raw", "wb").write(frame([(3, 3, (0x31, 0x21, 0x11))]))
pad = frame([]); pad[0*P + W*4] = 0x00
open(f"{t}/pad.raw", "wb").write(pad)
PY
r() { echo "raw:8:6:40:$T/$1"; }
expect "same frame: nothing" "0 - - - -" "$("$T/frames" diff "$(r a.raw)" "$(r same.raw)" 0 0)"
expect "stale border pixels: count and box" "2 2 3 5 4" "$("$T/frames" diff "$(r a.raw)" "$(r border.raw)" 0 0)"
expect "a change in the bar rows is not compared" "0 - - - -" "$("$T/frames" diff "$(r a.raw)" "$(r bar.raw)" 1 0)"
expect "the bar rows are compared without a skip" "1 1 0 1 0" "$("$T/frames" diff "$(r a.raw)" "$(r bar.raw)" 0 0)"
expect "within the tolerance" "0 - - - -" "$("$T/frames" diff "$(r a.raw)" "$(r near.raw)" 0 1)"
expect "past the tolerance" "1 3 3 3 3" "$("$T/frames" diff "$(r a.raw)" "$(r near.raw)" 0 0)"
expect "row padding is not a pixel" "0 - - - -" "$("$T/frames" diff "$(r a.raw)" "$(r pad.raw)" 0 0)"
"$T/frames" diff "$(r a.raw)" "raw:8:7:40:$T/a.raw" 0 0 >/dev/null 2>&1; expect "a short file is refused" 1 $?
exit $fail
