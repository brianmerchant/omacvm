#!/bin/bash
# Input latency, end to end: a Mac key or pointer event -> the first changed
# picture of the VM's window on screen. A throwaway OmacVM.app VM runs on a
# virtual Mac display of its own (never the user's screens, never the focus);
# tests/graphics/pacing/inputlat.swift posts the events into QEMU's own event
# queue (AppKit, QEMU's window code, the guest) and times the change with
# ScreenCaptureKit. QEMU's trace (-msg timestamp=on) splits each event into
# Mac -> QEMU input, QEMU input -> the guest's next flush, flush -> screen.
#   src/tests/input-latency-vm.sh --runtime DIR --vm DIR --ssh-port PORT [--hz 60|120]
#        [--count N] [--modes "key pointer keymove qmpkey"] [--env K=V]... [--hw-cursor] [--out DIR]
# DIR (vm): a COPY of an OmacVM.app VM made by omacvm apply (disk.img,
# efi-vars.fd); the test writes to it. --env passes settings to QEMU for an
# A/B run (e.g. OMACVM_GL_VSYNC=0). --hw-cursor: the guest's pointer on
# virtio-gpu's cursor plane (OMACVM_HW_CURSOR=1, omacvm.hwcursor=1).
# Each mode prints a JSON summary; --out keeps the raw rows, QEMU's log and
# the breakdown (breakdown.json).
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
RT=""; VMD=""; PORT=""; HZ=60; COUNT=40; MODES="key pointer keymove qmpkey"; OUT=""; HWC=0
FW=$R/app/runtime/.build/firmware/edk2-aarch64-code.fd
QENV=()
while (( $# )); do
  case $1 in
    --runtime) RT=$2; shift 2 ;;
    --vm) VMD=$2; shift 2 ;;
    --ssh-port) PORT=$2; shift 2 ;;
    --firmware) FW=$2; shift 2 ;;
    --hz) HZ=$2; shift 2 ;;
    --count) COUNT=$2; shift 2 ;;
    --modes) MODES=$2; shift 2 ;;
    --env) QENV+=("$2"); shift 2 ;;
    --hw-cursor) HWC=1; shift ;;
    --out) OUT=$2; shift 2 ;;
    *) sed -n '9,10s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
  esac
done
[[ -x $RT/bin/qemu-system-aarch64 && -f $VMD/disk.img && -f $VMD/efi-vars.fd && $PORT =~ ^[0-9]+$ && -f $FW &&
   $HZ =~ ^(60|120)$ && $COUNT =~ ^[0-9]+$ ]] || { sed -n '9,10s/^# \{0,1\}//p' "$0" >&2; exit 2; }
[[ -e $HOME/.omacvm-user-testing ]] && { echo "input-latency-vm: the user is testing: no VM (STANDARDS 18)" >&2; exit 1; }
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && { echo "input-latency-vm: port $PORT is in use" >&2; exit 1; }

NAME="OmacVM T-input-latency"
PAT="-name $NAME -machine"
W=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-input-latency.XXXXXX")
[[ -n $OUT ]] || OUT=$W/out
mkdir -p "$OUT"
LOG=$OUT/qemu.log
VD_PID=""
cleanup() {
  pgrep -f -- "$PAT" >/dev/null && gssh "sync; systemctl poweroff" >/dev/null 2>&1
  for _ in $(seq 40); do pgrep -f -- "$PAT" >/dev/null || break; sleep 1; done
  pkill -f -- "$PAT" 2>/dev/null
  [[ -n $VD_PID ]] && kill "$VD_PID" 2>/dev/null
  rm -rf "$W/run" "$W/inputlat" "$W/vdisplay"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

gssh() {
  ssh -i "$HOME/.ssh/omacvm" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@127.0.0.1 "$@"
}

swiftc -O "$R/tests/graphics/pacing/inputlat.swift" -o "$W/inputlat" || exit 1
clang -fobjc-arc -framework Foundation -framework CoreGraphics -framework AppKit \
  "$R/tests/graphics/pacing/vdisplay.m" -o "$W/vdisplay" || exit 1

# One virtual display of our own for the whole run (STANDARDS 32: created once, own serial).
"$W/vdisplay" 1440 900 "$HZ" 3600 > "$W/vd.out" 2>&1 &
VD_PID=$!
for _ in $(seq 40); do grep -qE '^(id=|display )[0-9]+' "$W/vd.out" && break; sleep 0.25; done
VD=$(grep -oE '[0-9]+' <<<"$(grep -E '^(id=|display )' "$W/vd.out" | head -1)" | head -1)
[[ -n $VD ]] || { echo "input-latency-vm: no virtual display: $(cat "$W/vd.out")" >&2; exit 1; }
sleep 2
SKIP=$(swift -e 'import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &n)
print(ids[0..<Int(n)].map(String.init).joined(separator: ","))' 2>/dev/null | tr ',' '\n' | grep -vx "$VD" | paste -sd, -)
[[ -n $SKIP ]] || { echo "input-latency-vm: could not list the Mac's displays" >&2; exit 1; }
echo "virtual display $VD at $HZ Hz; left alone: $SKIP; settings: ${QENV[*]:-none}; hardware cursor: $HWC"

RUN=$W/run; mkdir -p "$RUN"
TRACE=(-trace 'input_event_key_qcode' -trace 'input_event_abs' -trace 'virtio_gpu_cmd_res_flush'
       -trace 'virtio_gpu_update_cursor' -trace 'cocoa_present_direct' -trace 'cocoa_present_frame')
SMB=()
((HWC)) && { QENV+=(OMACVM_HW_CURSOR=1); SMB=(-smbios type=11,value=omacvm.hwcursor=1); }
env OMACVM_PRODUCT_NAME="$NAME" OMACVM_SLIRP_HOST_PORTS=1 OMACVM_NOTCH=0 \
  OMACVM_TEST_SKIP_DISPLAYS="$SKIP" OMACVM_TEST_MAIN_DISPLAY="$VD" OMACVM_BACKGROUND=1 \
  OMACVM_TEST_POINTER=1 OMACVM_DISPLAY_SOCKET="$RUN/display" ${QENV[@]+"${QENV[@]}"} \
  "$RT/bin/qemu-system-aarch64" -name "$NAME" -machine virt,gic-version=3 -accel hvf \
  -cpu host,pmu=off -smp 4,sockets=1,cores=4,threads=1 -m 8192M -nodefaults \
  -action reboot=reset,shutdown=poweroff \
  -drive "if=pflash,format=raw,readonly=on,file=$FW" \
  -drive "if=pflash,format=raw,file=$VMD/efi-vars.fd" \
  -drive "if=none,id=disk,file=$VMD/disk.img,format=raw,cache=writeback,discard=unmap" \
  -device nvme,serial=omacvm,drive=disk,bootindex=0 \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device virtio-net-pci,netdev=net0,romfile= \
  -device virtio-gpu-gl-pci,max_outputs=1,xres=1920,yres=1080,romfile= \
  -display "cocoa,gl=on,show-cursor=$( ((HWC)) && echo on || echo off),zoom-to-fit=on,full-screen=off,full-grab=on,immersive=off,swap-opt-cmd=off" \
  -device virtio-keyboard-pci,romfile= -device virtio-tablet-pci,romfile= \
  -object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 \
  ${SMB[@]+"${SMB[@]}"} "${TRACE[@]}" \
  -msg timestamp=on -serial none -monitor none -qmp "unix:$RUN/qmp,server=on,wait=off" \
  -device virtio-serial-pci,id=vser0 \
  -chardev "socket,id=disp0,path=$RUN/display,server=on,wait=off" \
  -device virtserialport,bus=vser0.0,nr=5,chardev=disp0,name=org.omacvm.display \
  > "$LOG" 2>&1 &
start=$(date +%s)

wait_desktop() {
  local i
  for i in $(seq 120); do
    gssh 'ls /run/user/*/hypr/*/.socket.sock' >/dev/null 2>&1 && return 0
    pgrep -f -- "$PAT" >/dev/null || { echo "QEMU exited:" >&2; tail -5 "$LOG" >&2; return 1; }
    sleep 2
  done
  return 1
}
wait_desktop || { echo "input-latency-vm: no desktop within 4 minutes" >&2; exit 1; }
echo "desktop up after $(( $(date +%s) - start )) s"
# STANDARDS 18a/25: nothing of this VM reaches the Mac (no clipboard port; Mac-link units off).
gssh 'for u in omacvm-gestures omacvm-notchcast; do systemctl disable --now $u >/dev/null 2>&1; done; true'
QPID=$(pgrep -f -- "$PAT" | head -1)

# A terminal that fills the workspace, its cursor not blinking (the only change is the typed text).
gssh 'bash -s' <<'GUEST'
source /etc/omacvm/env 2>/dev/null
U=${OMACVM_USER:-$(id -nu 1000)}; X=/run/user/$(id -u "$U")
SIG=$(ls "$X/hypr" | head -1)
hc() { sudo -u "$U" env XDG_RUNTIME_DIR=$X HYPRLAND_INSTANCE_SIGNATURE=$SIG hyprctl "$@"; }
if command -v alacritty >/dev/null; then T="alacritty -o cursor.blinking=\"Never\" -e bash --norc --noprofile"
else T="foot -o cursor.blink=no bash --norc --noprofile"; fi
hc dispatch exec "$T" >/dev/null
sleep 3
echo "guest: $(hc -j clients | python3 -c 'import json,sys; print([c["class"] for c in json.load(sys.stdin)])')"
echo "guest: no_hardware_cursors $(hc getoption cursor:no_hardware_cursors 2>/dev/null | head -1)"
GUEST
sleep 2

for m in $MODES; do
  case $m in
    qmpkey) QMP=$RUN/qmp "$W/inputlat" "$QPID" key "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary" ;;
    key|pointer|keymove) "$W/inputlat" "$QPID" "$m" "$COUNT" "$OUT/$m.jsonl" | tee "$OUT/$m.summary" ;;
    *) echo "unknown mode $m" >&2 ;;
  esac
done

# Where the time goes: QEMU's trace against each event's post time and screen time.
python3 - "$OUT" "$MODES" <<'PY' | tee "$OUT/breakdown.json"
import datetime, json, os, re, statistics, sys
out, modes = sys.argv[1], sys.argv[2].split()
ev = []
for line in open(os.path.join(out, "qemu.log"), errors="replace"):
    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)Z? (\w+)", line)
    if not m:
        continue
    t = datetime.datetime.fromisoformat(m.group(1)).replace(tzinfo=datetime.timezone.utc).timestamp() * 1e6
    name = m.group(2)
    if name == "input_event_key_qcode" and "down 1" not in line:
        continue
    ev.append((t, name))
ev.sort()
def first(name, after, within=300e3):
    for t, n in ev:
        if t > after + within:
            return None
        if t >= after and n == name:
            return t
    return None
res = {}
for m in modes:
    p = os.path.join(out, m + ".jsonl")
    if not os.path.exists(p):
        continue
    inp, guest, present, cur = [], [], [], []
    for row in map(json.loads, open(p)):
        if row["lat_ms"] is None:
            continue
        post, screen = row["post_us"], row["post_us"] + row["lat_ms"] * 1e3
        q = first("input_event_abs" if m == "pointer" else "input_event_key_qcode", post)
        if q is None or q > screen:
            continue
        inp.append((q - post) / 1e3)
        c = first("virtio_gpu_update_cursor", q)
        if m == "pointer" and c is not None and c < screen:
            cur.append((c - q) / 1e3)
        f = first("virtio_gpu_cmd_res_flush", q)
        if f is not None and f < screen:
            guest.append((f - q) / 1e3)
            present.append((screen - f) / 1e3)
    med = lambda a: round(statistics.median(a), 2) if a else None
    res[m] = {"n": len(inp), "mac_to_qemu_ms": med(inp), "qemu_to_guest_flush_ms": med(guest),
              "flush_to_screen_ms": med(present), "qemu_to_cursor_cmd_ms": med(cur)}
print(json.dumps(res))
PY
echo "input-latency-vm: done (raw: $OUT)"
