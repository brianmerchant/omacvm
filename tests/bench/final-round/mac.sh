#!/bin/bash
# The final round on macOS itself: the baseline (100 %).
#   mac.sh [--runs 3] [--only throughput,vkpeak,geekbench,browser] [--headless] OUT.jsonl
# Same tests as vm.sh, on the bare Mac: the GPU throughput page (timer and
# wall method), Aquarium 30k + Basemark Web 3.0 in Google Chrome (full
# screen, 1728x1080 at 2x as in the VMs: checked first), vkpeak through
# MoltenVK and Geekbench GPU (Metal and OpenCL). glmark2 and vkmark have no
# macOS version. --headless runs the throughput page without a window (it
# draws offscreen, so the score is the same; for checks only).
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
RUNS=3; ONLY=throughput,vkpeak,geekbench,browser; HEADLESS=
while [ "${1:-}" != "${1#--}" ]; do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --headless) HEADLESS=--headless; shift ;;
    *) die "unknown option $1" ;;
  esac
done
OUT=${1:-}
[ -n "$OUT" ] || { sed -n '2,9p' "$0" >&2; exit 2; }
want() { case ,$ONLY, in *,$1,*) return 0 ;; esac; return 1; }
[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] || die "Google Chrome is missing"

preflight
if want browser; then   # Chrome's page as agreed, before the tests that depend on the window
  vp=$(python3 "$REPO/tests/bench/gpu-throughput/run.py" --viewport-only 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("viewport", ""))' 2>/dev/null)
  if [ "$vp" != "$VIEWPORT" ]; then
    [ "${FINAL_ROUND_ALLOW_BUSY:-0}" = 1 ] || die "Chrome's page is ${vp:-unknown}, the round needs $VIEWPORT (built-in display, full screen)"
    PRELIM=true PRELIM_WHY="${PRELIM_WHY:+$PRELIM_WHY; }Chrome page ${vp:-unknown}"
  fi
fi
each() {   # test: one rec per JSON line on stdin
  local l
  while IFS= read -r l; do case $l in '{'*) rec mac "$1" "$l" >/dev/null ;; esac; done
}
if want throughput; then
  say "mac: GPU throughput page x$RUNS"
  i=0
  while [ $i -lt "$RUNS" ]; do
    for m in timer wall; do python3 "$REPO/tests/bench/gpu-throughput/run.py" --method $m $HEADLESS | each gpu-throughput; done
    i=$((i + 1))
  done
fi
want vkpeak && { say "mac: vkpeak x$RUNS"; bash "$REPO/tests/bench/vkpeak/vkpeak.sh" --runs "$RUNS" 2>/dev/null | each vkpeak; }
if want geekbench; then
  say "mac: Geekbench GPU (Metal, OpenCL) x$RUNS"
  tmp=$FR_TMP/geekbench.jsonl
  bash "$REPO/src/bench/bench.sh" --runs "$RUNS" --only gpu "$tmp" >/dev/null 2>&1
  each geekbench < "$tmp"
fi
if want browser; then
  say "mac: Aquarium 30k + Basemark Web 3.0 x$RUNS"
  tmp=$FR_TMP/browser.jsonl
  bash "$REPO/src/bench/bench.sh" --runs "$RUNS" --only aquarium,basemark "$tmp" >/dev/null 2>&1
  each browser < "$tmp"
fi
say "mac: done, $OUT"
