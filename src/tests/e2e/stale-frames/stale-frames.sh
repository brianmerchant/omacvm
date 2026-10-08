#!/bin/bash
# Stale frames after focus changes (#167): what the Mac shows and what the guest's
# scanout holds must not change when Hyprland draws the whole output again.
#
# Each round changes the focus between two windows (keys: Hyprland's focus
# dispatcher, pointer: a uinput tablet crossing into the other window with
# focus following the mouse, burst: quick focus changes back and forth), waits
# for the border animation, then takes
#   - the scanout buffer itself (scanout-read: no frame is asked for), and
#   - the VM window on the Mac (ScreenCaptureKit, also when the window is on another Space),
# then makes Hyprland draw everything again (grim to /dev/null: screencopy
# damages the whole output) and takes both again. A difference below the bar is
# a stale frame: in the guest's buffer (Hyprland's damage / buffer age, or the
# host's rendering of it) or on the Mac (a frame QEMU did not show).
#
# usage: stale-frames.sh --vm NAME [--rounds N] [--modes keys,pointer,burst] [--settle S] [--out DIR]
# NAME: a test VM in the test app's VMs folder, running in the test app
# (src/tests/e2e/README.md); any other VM is refused.
# Needs in the VM: gcc, libdrm headers, foot, grim. Leaves the VM as it found it
# (its two windows closed, the workspace it was on).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
VM="" ROUNDS=40 MODES=keys,pointer,burst SETTLE=0.8 OUT=""
while (($#)); do
  case $1 in
    --vm) VM=$2; shift 2 ;;
    --rounds) ROUNDS=$2; shift 2 ;;
    --modes) MODES=$2; shift 2 ;;
    --settle) SETTLE=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) echo "stale-frames: unknown argument $1" >&2; exit 64 ;;
  esac
done
[[ -n $VM ]] || { echo "usage: stale-frames.sh --vm NAME [...]" >&2; exit 64; }
# shellcheck source=../test-vms.sh
source "$HERE/../test-vms.sh"
VMD=$(e2e_vm_guard org.omacvm.app.test "$VM") || exit 3
OUT=${OUT:-$HOME/omacvm-e2e/stale-frames-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" || exit 3
KEY=$HOME/.ssh/omacvm
PORT=$(sed -n "s/^SSH_PORT=//p" "$VMD/vm.env" | tr -d "'\"")
QPAT='(runtime/bin/OmacVM|MacOS/OmacVM-VM) -name'
QPID=$(pgrep -f "$QPAT $VM( |$)" | head -1)
[[ -n $QPID ]] || { echo "stale-frames: $VM does not run" >&2; exit 3; }
CTL=$OUT/.ssh-ctl
SSHO=(-i "$KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ControlMaster=auto -o "ControlPath=$CTL" -o ControlPersist=300)
g() { ssh "${SSHO[@]}" root@127.0.0.1 "$@"; }
# as the desktop user, with Hyprland's environment
U='u=$(sed -n "s/^OMACVM_USER=//p" /etc/omacvm/env); uid=$(id -u $u); export XDG_RUNTIME_DIR=/run/user/$uid WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$(ls /run/user/$uid/hypr | head -1); runuser -u $u --preserve-environment --'
hc() { g "$U hyprctl $(printf '%q ' "$@")"; }
log() { echo "== $(date +%H:%M:%S) $*" | tee -a "$OUT/run.log"; }
FRAMES=$OUT/frames
swiftc -O "$HERE/frames.swift" -o "$FRAMES" 2>"$OUT/frames-build.log" || { echo "stale-frames: frames.swift does not build" >&2; exit 3; }

# The VM window on the Mac: the QEMU process's window named after the VM.
WID=$(/usr/bin/python3 - "$QPID" "$VM" <<'PY'
import ctypes, ctypes.util, sys
cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]; cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]; cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]; cf.CFDictionaryGetValue.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]; cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
def key(s): return cf.CFStringCreateWithCString(None, s.encode(), 0x08000100)
def num(d, k):
    v = cf.CFDictionaryGetValue(d, key(k)); n = ctypes.c_long(0)
    if v: cf.CFNumberGetValue(v, 4, ctypes.byref(n))
    return n.value
def s(d, k):
    v = cf.CFDictionaryGetValue(d, key(k)); b = ctypes.create_string_buffer(512)
    return b.value.decode() if v and cf.CFStringGetCString(v, b, 512, 0x08000100) else ""
arr = cg.CGWindowListCopyWindowInfo(0, 0)
for i in range(cf.CFArrayGetCount(arr)):
    d = cf.CFArrayGetValueAtIndex(arr, i)
    if num(d, "kCGWindowOwnerPID") == int(sys.argv[1]) and s(d, "kCGWindowName").startswith(sys.argv[2]):
        print(num(d, "kCGWindowNumber")); break
PY
)
[[ -n $WID ]] || { echo "stale-frames: no window of $VM (pid $QPID)" >&2; exit 3; }

log "VM $VM (pid $QPID, window $WID), rounds $ROUNDS per mode, modes $MODES, settle $SETTLE s"
g "mkdir -p /root/omacvm-e2e" || exit 3
for f in scanout-read pointer; do
  g "cat > /root/omacvm-e2e/$f.c" < "$HERE/$f.c" || exit 3
done
g "cd /root/omacvm-e2e && gcc -O2 -I/usr/include/libdrm scanout-read.c -o scanout-read -ldrm && gcc -O2 pointer.c -o pointer" \
  > "$OUT/guest-build.log" 2>&1 || { echo "stale-frames: guest tools do not build (gcc, libdrm)" >&2; exit 3; }

# Output, its size and the bar (rows the clock may change: not compared).
read -r MON MW MH TOP SCALE PREVWS < <(hc -j monitors | /usr/bin/python3 -c '
import json, sys
m = [m for m in json.load(sys.stdin) if m.get("focused")] or [None]
m = m[0]
print(m["name"], m["width"], m["height"], int(m["reserved"][1] * m["scale"]) + 2, m["scale"], m["activeWorkspace"]["id"])')
log "output $MON ${MW}x$MH scale $SCALE, bar rows 0-$TOP not compared, workspace was $PREVWS"
cleanup() {
  g "pkill -f '/root/omacvm-e2e/pointer'; pkill -f 'sleep 100000'; rm -f /root/omacvm-e2e/pointer.in" 2>/dev/null
  g "pkill -f 'foot --app-id omacvm-e2e-'" 2>/dev/null
  hc dispatch "hl.dsp.focus({ workspace = \"$PREVWS\" })" >/dev/null 2>&1
  ssh "${SSHO[@]}" -O exit root@127.0.0.1 >/dev/null 2>&1
}
trap cleanup EXIT
WS=$(( PREVWS - (PREVWS - 1) % 10 + 9 ))   # the output's 10th workspace (per-display workspaces: 1..10, 11..20, ...)
hc dispatch "hl.dsp.focus({ workspace = \"$WS\" })" >/dev/null
sleep 0.5
g "$U sh -c 'cd; setsid foot --app-id omacvm-e2e-a >/dev/null 2>&1 & sleep 1; setsid foot --app-id omacvm-e2e-b >/dev/null 2>&1 &'"
sleep 2
read -r AX BX CY < <(hc -j clients | /usr/bin/python3 -c '
import json, sys
c = sorted([c for c in json.load(sys.stdin) if c["class"].startswith("omacvm-e2e-")], key=lambda c: c["at"][0])
if len(c) != 2: sys.exit(1)
print(c[0]["at"][0] + c[0]["size"][0] // 2, c[1]["at"][0] + c[1]["size"][0] // 2, c[0]["at"][1] + c[0]["size"][1] // 2)') \
  || { log "the two test windows did not open side by side"; exit 3; }
read -r LW LH < <(hc -j monitors | /usr/bin/python3 -c '
import json, sys
m = [m for m in json.load(sys.stdin) if m.get("focused")][0]; print(int(m["width"] / m["scale"]), int(m["height"] / m["scale"]))')
abs() { echo $(( $1 * 65535 / $2 )); }
g "rm -f /root/omacvm-e2e/pointer.in; mkfifo /root/omacvm-e2e/pointer.in; setsid sh -c 'sleep 100000 > /root/omacvm-e2e/pointer.in' </dev/null >/dev/null 2>&1 & setsid /root/omacvm-e2e/pointer < /root/omacvm-e2e/pointer.in > /root/omacvm-e2e/pointer.log 2>&1 & sleep 1"


printf 'mode\tround\tfocus\tguest\tmac\n' > "$OUT/rounds.tsv"
BAD=0 TOTAL=0 MISSED=0
focus() {   # MODE TARGET(a|b)
  local o; [[ $2 == a ]] && o=b || o=a
  case $1 in
    keys) hc dispatch "hl.dsp.focus({ window = \"class:omacvm-e2e-$2\" })" >/dev/null ;;
    burst)   # back and forth three times, 20 ms apart, ending on TARGET
      g "$U sh -c 'for t in $o $2 $o $2 $o $2; do hyprctl dispatch \"hl.dsp.focus({ window = \\\"class:omacvm-e2e-\$t\\\" })\" >/dev/null; sleep 0.02; done'" ;;
    pointer)   # across the gap into the other window, 30 steps at 120 Hz (focus follows the mouse)
      local from=$BX to=$AX; [[ $2 == b ]] && { from=$AX; to=$BX; }
      g "echo '$(abs "$from" "$LW") $(abs "$CY" "$LH") $(abs "$to" "$LW") $(abs "$CY" "$LH") 30 8000' > /root/omacvm-e2e/pointer.in"
      sleep 0.3 ;;
  esac
}
grab() {   # TAG: the guest's scanout and the Mac window
  g "/root/omacvm-e2e/scanout-read $MON /tmp/omacvm-e2e-scanout.raw >/dev/null && cat /tmp/omacvm-e2e-scanout.raw" > "$OUT/$1.raw"
  "$FRAMES" capture "$WID" "$OUT/$1.png"
}
for mode in ${MODES//,/ }; do
  for ((i = 1; i <= ROUNDS; i++)); do
    (( i % 2 )) && t=a || t=b
    focus "$mode" "$t"
    sleep "$SETTLE"
    fw=$(hc -j activewindow | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("class",""))' 2>/dev/null)
    [[ $fw == "omacvm-e2e-$t" ]] || { MISSED=$((MISSED + 1)); log "$mode round $i: focus is on '$fw', not omacvm-e2e-$t"; }
    grab before
    hc dispatch "hl.dsp.exec_cmd(\"grim /dev/null\")" >/dev/null   # screencopy: the whole output again
    sleep 0.4
    grab after
    PITCH=$(( MW * 4 ))
    gd=$("$FRAMES" diff "raw:$MW:$MH:$PITCH:$OUT/before.raw" "raw:$MW:$MH:$PITCH:$OUT/after.raw" "$TOP" 0)
    md=$("$FRAMES" diff "$OUT/before.png" "$OUT/after.png" "$TOP" 2)
    TOTAL=$((TOTAL + 1))
    printf '%s\t%s\t%s\t%s\t%s\n' "$mode" "$i" "$fw" "$gd" "$md" >> "$OUT/rounds.tsv"
    if [[ $gd != 0\ * || $md != 0\ * ]]; then
      BAD=$((BAD + 1))
      for f in before.raw after.raw before.png after.png; do cp "$OUT/$f" "$OUT/$mode-$i-$f"; done
      log "$mode round $i: STALE guest [$gd] mac [$md] (kept as $mode-$i-*)"
    fi
  done
  log "$mode: done"
done
rm -f "$OUT"/before.* "$OUT"/after.*
log "result: $BAD stale of $TOTAL rounds, $MISSED without the focus change (rounds.tsv)"
(( BAD == 0 && MISSED == 0 ))
