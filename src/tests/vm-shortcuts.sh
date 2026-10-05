#!/bin/bash
# macOS's shortcuts reach the VM, end to end against a real QEMU: every enabled
# chord of macOS's list (app/runtime/Tests/keys/mac-shortcuts.tsv, the keys the
# patched Cocoa UI gives the guest for it) is typed into a headless QEMU
# (-display none: no window, no disk, no firmware, no Mac helper link; a few
# seconds, killed after) through QMP, and QEMU's own trace must show each key
# down and up, in order, at the guest's virtio keyboard. Skipped without a
# QEMU (CI) or while the user tests on this Mac (STANDARDS 18).
#   vm-shortcuts.sh [QEMU]   default: the app's runtime build, else OmacVM.app's
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
Q=${1:-}
for c in "$R/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64" "$HOME/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM"; do
  [[ -z $Q && -x $c ]] && Q=$c
done
[[ -n $Q ]] || { echo "skip: no QEMU here (build the app's runtime, or pass one)"; exit 0; }
[[ ! -e $HOME/.omacvm-user-testing ]] || { echo "skip: the user is testing on this Mac (~/.omacvm-user-testing)"; exit 0; }
T=$(mktemp -d /tmp/omacvm-shortcuts.XXXXXX); QPID=
trap 'if [[ -n $QPID ]]; then kill "$QPID" 2>/dev/null || true; wait 2>/dev/null || true; fi; rm -rf "$T"' EXIT
K=$R/app/runtime/Tests/keys
patch -s -d "$T" -p1 -f -i "$R/app/runtime/patches/omacvm-cocoa-shortcuts-logic.patch"
cc -std=c11 -Wall -Wextra -Werror -I"$T/ui" "$K/test-shortcuts.c" -o "$T/test-shortcuts"
"$T/test-shortcuts" --qcodes "$K/mac-shortcuts.tsv" > "$T/chords"
S=$T/qmp
"$Q" -name "OmacVM T-shortcuts" -machine virt -accel hvf -cpu host -m 256M -nodefaults -S -display none \
  -device virtio-keyboard-pci,romfile= -serial none -monitor none \
  -qmp "unix:$S,server=on,wait=off" -trace "input_event_key_qcode" 2> "$T/trace" &
QPID=$!
for _ in $(seq 50); do [[ -S $S ]] && break; sleep 0.1; done
[[ -S $S ]] || { echo "FAIL QEMU did not open its QMP socket"; cat "$T/trace"; exit 1; }
python3 - "$S" "$T/chords" "$T/expected" <<'PY'
import json, socket, sys, time
sock = socket.socket(socket.AF_UNIX); sock.connect(sys.argv[1]); f = sock.makefile("rw")
def cmd(c, **a):
    f.write(json.dumps({"execute": c, "arguments": a} if a else {"execute": c}) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r: return r
        if "error" in r: raise SystemExit(f"FAIL {c}: {r['error']}")
f.readline(); cmd("qmp_capabilities"); cmd("cont")
exp = open(sys.argv[3], "w")
for line in open(sys.argv[2]):
    keys = line.split("\t")[0].split()[1:]
    ev = lambda k, d: {"type": "key", "data": {"down": d, "key": {"type": "qcode", "data": k}}}
    # Modifiers down, the key down and up, modifiers up: as a hand types it.
    cmd("input-send-event", events=[ev(k, True) for k in keys])
    cmd("input-send-event", events=[ev(k, False) for k in reversed(keys)])
    for k in keys: exp.write(f"{k} 1\n")
    for k in reversed(keys): exp.write(f"{k} 0\n")
    time.sleep(0.002)
cmd("stop")
PY
sleep 0.3
# QEMU's trace lines: "input_event_key_qcode conidx 0, qcode meta_l, down 1".
sed -n 's/.*input_event_key_qcode.*qcode \([a-z0-9_]*\), down \([01]\).*/\1 \2/p' "$T/trace" > "$T/got"
chords=$(grep -c . "$T/chords"); keys=$(grep -c . "$T/expected")
if cmp -s "$T/expected" "$T/got"; then
  echo "ok   QEMU's input layer got all $chords chords of macOS's shortcut list ($keys key events, in order) for the guest's keyboard"
else
  echo "FAIL QEMU's trace differs from the chords typed (expected left, trace right):"
  diff "$T/expected" "$T/got" | head -20
  exit 1
fi
