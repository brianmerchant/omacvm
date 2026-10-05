#!/bin/bash
# The final round on macOS itself: the baseline (100 %).
#   mac.sh [--runs 3] [--only throughput,vkpeak,browser] [--headless] OUT.jsonl
# Same tests as vm.sh, on the bare Mac: the GPU throughput page and Aquarium
# 30k + Basemark Web 3.0 in Google Chrome (full screen, as in the VMs), and
# vkpeak through MoltenVK. glmark2 has no macOS version. --headless runs the
# throughput page without a window (the page draws offscreen, so the score is
# the same; for checks while someone works on the Mac).
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
RUNS=3; ONLY=throughput,vkpeak,browser; HEADLESS=
while [ "${1:-}" != "${1#--}" ]; do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --headless) HEADLESS=--headless; shift ;;
    *) die "unknown option $1" ;;
  esac
done
OUT=${1:-}
[ -n "$OUT" ] || { sed -n '2,8p' "$0" >&2; exit 2; }
want() { case ,$ONLY, in *,$1,*) return 0 ;; esac; return 1; }
[ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] || die "Google Chrome is missing"

preflight
each() {   # test: one rec per JSON line on stdin
  local l
  while IFS= read -r l; do case $l in '{'*) rec mac "$1" "$l" >/dev/null ;; esac; done
}
if want throughput; then
  say "mac: GPU throughput page x$RUNS"
  i=0
  while [ $i -lt "$RUNS" ]; do python3 "$REPO/tests/bench/gpu-throughput/run.py" $HEADLESS | each gpu-throughput; i=$((i + 1)); done
fi
want vkpeak && { say "mac: vkpeak x$RUNS"; bash "$REPO/tests/bench/vkpeak/vkpeak.sh" --runs "$RUNS" 2>/dev/null | each vkpeak; }
if want browser; then
  say "mac: Aquarium 30k + Basemark Web 3.0 x$RUNS"
  tmp=$(mktemp)
  bash "$REPO/src/bench/bench.sh" --runs "$RUNS" --only aquarium,basemark "$tmp" >/dev/null 2>&1
  each browser < "$tmp"; rm -f "$tmp"
fi
say "mac: done, $OUT"
