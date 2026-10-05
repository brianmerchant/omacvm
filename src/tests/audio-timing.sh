#!/bin/bash
# Offline checks for the sound-on-a-busy-Mac change (no VM, no QEMU build):
#  - the tone glitch detector finds made-up gaps and skips (app/runtime/Tests/audio/glitches.py)
#  - the launcher, QEMU's patch and omacvm check use the same switch and log lines
#    (OMACVM_MAIN_LOOP_QOS=default; "main loop QoS: user-interactive|default|... refused")
# Exit 0 when every check passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/app/runtime/patches/qemu-darwin-main-loop-qos.patch
RUNNER=$R/app/app/Sources/OmacVM/Runner.swift
CHECK=$R/src/cmd/check.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

check "glitch detector finds a gap, a skip and a repeat, none in a clean tone" \
  python3 "$R/app/runtime/Tests/audio/glitches.py" --selftest
check "patch is pinned in SHA256SUMS" grep -q " qemu-darwin-main-loop-qos.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "runtime build applies the patch" grep -q "patches/qemu-darwin-main-loop-qos.patch" "$R/app/runtime/build-qemu-gpu-runtime.sh"
check "patch reads OMACVM_MAIN_LOOP_QOS=default" grep -q 'getenv("OMACVM_MAIN_LOOP_QOS")' "$P"
check "launcher sets OMACVM_MAIN_LOOP_QOS=default for audioClassic" \
  grep -q 'env\["OMACVM_MAIN_LOOP_QOS"\] = "default"' "$RUNNER"
# Each line QEMU can log gets the verdict omacvm check means for it.
verdict() {   # LOG_LINE -> what check.sh's case gives
  local q=$1
  case $q in
    "") echo none ;;
    *user-interactive) echo ok-ui ;;
    *refused*) echo warn ;;
    *) echo ok-default ;;
  esac
}
for line in "main loop QoS: user-interactive" "main loop QoS: default" "main loop QoS: default (user-interactive refused)"; do
  check "patch logs '$line'" grep -qF "OmacVM: $line" "$P"
done
check "check.sh: user-interactive is ok" test "$(verdict 'main loop QoS: user-interactive')" = ok-ui
check "check.sh: refused is a warning" test "$(verdict 'main loop QoS: default (user-interactive refused)')" = warn
check "check.sh: default (audioClassic) is ok" test "$(verdict 'main loop QoS: default')" = ok-default
check "check.sh has the same cases" grep -qF '*user-interactive) ok "sound timing"' "$CHECK"
check "check.sh warns on refused" grep -qF '*refused*) warn "sound timing"' "$CHECK"
echo "audio-timing: $((N - FAIL))/$N ok"
exit $(( FAIL > 0 ))
