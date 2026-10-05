#!/bin/bash
# Offline checks for the sound-on-a-busy-Mac change (no VM, no QEMU build):
#  - the tone glitch detector finds made-up gaps and skips (app/runtime/Tests/audio/glitches.py)
#  - the launcher, QEMU's patches and omacvm check use the same switches and log lines
#    (OMACVM_MAIN_LOOP_QOS=default, hda-micro pace=off; "main loop QoS: ...", "HDA sound pacing on|off")
#  - a Mac audio device that does not answer: the playback-thread patch is built in, its
#    log lines match omacvm check's "sound" line, the test stub builds
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
HP=$R/app/runtime/patches/qemu-hda-no-catch-up.patch
check "pacing patch is pinned in SHA256SUMS" grep -q " qemu-hda-no-catch-up.patch$" "$R/app/runtime/patches/SHA256SUMS"
check "runtime build applies the pacing patch" grep -q "patches/qemu-hda-no-catch-up.patch" "$R/app/runtime/build-qemu-gpu-runtime.sh"
check "pacing is a codec property, on by default" grep -qF 'DEFINE_PROP_BOOL("pace", HDAAudioState, pace, true)' "$HP"
check "launcher turns pacing off for audioClassic" grep -qF 'audiodev=snd0\(Settings.audioClassic ? ",pace=off" : "")' "$RUNNER"
check "pacing patch logs its state" grep -qF 'info_report("OmacVM: HDA sound pacing %s"' "$HP"
for line in "main loop QoS: user-interactive" "main loop QoS: default" "main loop QoS: default (user-interactive refused)"; do
  check "QoS patch logs '$line'" grep -qF "OmacVM: $line" "$P"
done
# check.sh's verdict for each pair of log lines QEMU can write (its own case, run here).
verdict() {   # QOS_LINE PACING_LINE -> the status check.sh prints
  local miclog TYPE=app out
  miclog=$(mktemp); printf 'OmacVM: %s\nOmacVM: %s\n' "$1" "$2" | grep -v 'OmacVM: $' > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n '/^# Sound on a busy Mac/,/^fi$/p' "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
check "check.sh: QoS + pacing on is ok" grep -q "^ok:QEMU's main loop at user-interactive QoS, sound card paced" <<<"$(verdict 'main loop QoS: user-interactive' 'HDA sound pacing on')"
check "check.sh: audioClassic is ok" grep -q "^ok:QEMU's own sound timing" <<<"$(verdict 'main loop QoS: default' 'HDA sound pacing off')"
check "check.sh: refused QoS warns" grep -q "^warn:" <<<"$(verdict 'main loop QoS: default (user-interactive refused)' 'HDA sound pacing on')"
check "check.sh: an old runtime prints nothing" test -z "$(verdict '' '')"
# A Mac audio device that does not answer (qemu-sdl-audio-playback-thread.patch).
PP=$R/app/runtime/patches/qemu-sdl-audio-playback-thread.patch
BUILD=$R/app/runtime/build-qemu-gpu-runtime.sh
check "playback-thread patch is pinned in SHA256SUMS" grep -q " qemu-sdl-audio-playback-thread.patch$" "$R/app/runtime/patches/SHA256SUMS"
cap_line=$(grep -n 'patches/qemu-sdl-audio-capture-thread.patch"' "$BUILD" | cut -d: -f1)
play_line=$(grep -n 'patches/qemu-sdl-audio-playback-thread.patch"' "$BUILD" | cut -d: -f1)
check "runtime build applies it after the capture-thread patch" test -n "$play_line" -a -n "$cap_line" -a "${play_line:-0}" -gt "${cap_line:-0}"
check "QEMU's start no longer opens the playback device" grep -qF -- '-    sdl->devid = sdl_open(&req, &obt, 0, sdl->device_name,' "$PP"
check "playback opens run on a helper thread" grep -qF '"sdl-out-open", sdl_out_open_thread' "$PP"
for line in "does not answer" "works again"; do
  check "playback-thread patch logs 'the Mac's audio device $line'" grep -qF "OmacVM: sound: the Mac's audio device $line" "$PP"
done
stub=$(mktemp -d)
check "the wedged-device test stub builds" clang -dynamiclib -Wall -Werror -o "$stub/aqhang.dylib" \
  "$R/app/runtime/Tests/audio/wedged-output-start.c" -framework AudioToolbox
rm -rf "$stub"
sound() {   # QEMU's log lines -> the status of check.sh's "sound" line
  local miclog TYPE=app out
  miclog=$(mktemp); printf '%s\n' "$@" > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n "/^# A Mac audio device that does not answer/,/^fi$/p" "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
NA="qemu-system-aarch64: OmacVM: sound: the Mac's audio device does not answer (no start within 3 s); the VM goes on without sound"
WA="qemu-system-aarch64: info: OmacVM: sound: the Mac's audio device works again"
check "check.sh: a device that does not answer warns with the fix" grep -q "^warn:Mac audio device not answering.*killall coreaudiod" <<<"$(sound "$NA")"
check "check.sh: one that works again is ok" grep -q "^ok:.*works again" <<<"$(sound "$NA" "$WA")"
check "check.sh: stuck again after that warns" grep -q "^warn:" <<<"$(sound "$NA" "$WA" "$NA")"
check "check.sh: a run without either line prints nothing" test -z "$(sound "OmacVM: HDA sound pacing on")"
echo "audio-timing: $((N - FAIL))/$N ok"
exit $(( FAIL > 0 ))
