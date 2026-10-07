#!/bin/bash
# Pointer flicker at the edge between the VM and Omanotch's strip (notch Macs,
# macOS full screen). MANUAL, not in CI: it needs a real notched display, a
# test VM in full screen with Omanotch on, Screen Recording and Accessibility
# (posting mouse events) for this shell.
#
# NEVER on a Mac someone is using: it moves the real pointer (HID-level
# events, so tracking areas fire like with a mouse).
#
# What it does: records the region around the pointer at 60 fps with the
# cursor (ScreenCaptureKit, fcap), moves the pointer up from the VM into the
# strip and back 20 times (slow: 300 ms per crossing, fast: 30 ms; fdrive),
# then finds frames with no cursor or a second one (analyze.py) and the
# longest stretch of them. One or two frames at a crossing are the guest's
# render latency; the flicker this guards against lasted 100-540 ms
# (Hyprland's cursor:invisible tick, tracks: notch-cursor-flicker).
#
# Usage: run.sh OUTDIR [X Y_VM Y_STRIP]   (points, top-left of the main display;
#        defaults 400 120 12: the pointer goes from y 120 in the VM to y 12 on
#        the strip at x 400; keep x away from the bar's items and the corners)
# Needs python3 with numpy and Pillow (OMACVM_PY=<python> to pick one).
# Exit: 0 every stretch <= 100 ms, 1 longer (flicker), 2 setup problem.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
out=${1:?usage: run.sh OUTDIR [X Y_VM Y_STRIP]}
x=${2:-400} yvm=${3:-120} ystrip=${4:-12}
py=${OMACVM_PY:-python3}
limit_ms=100
mkdir -p "$out/bin"
"$py" -c 'import numpy, PIL' 2>/dev/null || { echo "needs numpy and Pillow for $py" >&2; exit 2; }
swiftc -O -o "$out/bin/fcap" "$here/fcap.swift" 2>/dev/null
swiftc -O -o "$out/bin/fdrive" "$here/fdrive.swift" 2>/dev/null

# the region: 160 x 160 points around the path, from the top of the display
rx=$((x - 80)); [[ $rx -ge 0 ]] || rx=0
status=0
for run in slow:300:30 fast:30:20; do
  IFS=: read -r tag ms secs <<< "$run"
  d=$out/$tag
  rm -rf "$d"; mkdir -p "$d"
  echo "$rx 0 160 160" > "$d/cap.meta"
  "$out/bin/fcap" "$secs" "$d/cap.raw" "$rx" 0 160 160 > "$d/cap.out" 2>&1 &
  cap=$!
  sleep 1
  "$out/bin/fdrive" "$d/drive.log" cross "$x" "$yvm" "$ystrip" "$ms" 400 20
  wait "$cap" || { echo "$tag: capture failed: $(cat "$d/cap.out")" >&2; exit 2; }
  line=$("$py" -I "$here/analyze.py" "$d")
  echo "$tag: $line"
  longest=$(sed -n 's/.* \([0-9][0-9]*\) ms$/\1/p' <<< "$line")
  [[ -n $longest ]] || { echo "$tag: no result" >&2; exit 2; }
  if (( longest > limit_ms )); then
    echo "$tag: FAIL: a wrong cursor for $longest ms (more than $limit_ms); frames in $d/flag" >&2
    status=1
  fi
done
exit "$status"
