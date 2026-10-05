#!/bin/bash
# The media keys into an OmacVM.app VM, end to end against a real QEMU: started
# headless (-display none: no window, no guest, no disk, no firmware, no Mac
# helper link; paused first, then running a few seconds), with a QMP socket
# and a virtio keyboard as OmacVM.app starts them. Checks that the Bridge's code finds the socket from QEMU's
# command line and types the keys (QEMU's own trace shows each one), and that
# a busy socket fails fast. Skipped without a QEMU (CI).
#   test-vm-keys.sh [QEMU]   default: the app's runtime build, else OmacVM.app's
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$HERE/../../.." && pwd)
Q=${1:-}
for c in "$R/app/runtime/.build/qemu-gpu-runtime/bin/qemu-system-aarch64" "$HOME/Applications/OmacVM.app/Contents/Resources/runtime/bin/OmacVM"; do
  [[ -z $Q && -x $c ]] && Q=$c
done
[[ -n $Q ]] || { echo "skip: no QEMU here (build the app's runtime, or pass one)"; exit 0; }
# Never while the user tests on this Mac (STANDARDS 18).
[[ ! -e $HOME/.omacvm-user-testing ]] || { echo "skip: the user is testing on this Mac (~/.omacvm-user-testing)"; exit 0; }
T=$(mktemp -d /tmp/omacvm-vmkeys.XXXXXX); QPID=
trap 'if [[ -n $QPID ]]; then kill "$QPID" 2>/dev/null || true; wait 2>/dev/null || true; fi; rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -o "$T/vmkeys-test" "$HERE/keys-model.swift" "$HERE/vm-keys.swift" "$HERE/tests/vmkeys/main.swift" -framework AppKit
S=$T/run/x,y.qmp   # a comma in the path, as QEMU's option syntax doubles it
mkdir -p "$T/run"
"$Q" -name "OmacVM T-vmkeys" -machine virt -accel hvf -cpu host -m 256M -nodefaults -S -display none \
  -device virtio-keyboard-pci,romfile= -serial none -monitor none \
  -qmp "unix:${S//,/,,},server=on,wait=off" -trace "input_event_key_qcode" 2> "$T/trace" &
QPID=$!
for _ in $(seq 50); do [[ -S $S ]] && break; sleep 0.1; done
[[ -S $S ]] || { echo "FAIL QEMU did not open its QMP socket"; cat "$T/trace"; exit 1; }
fail=0
"$T/vmkeys-test" "$QPID" "$S" || fail=1
sleep 0.2
# QEMU's trace: each key down and up, as typed.
for k in volumeup audioplay audionext audioprev audiomute volumedown; do
  n=$(grep -c "qcode=.*$k\|$k" "$T/trace" || true)
  if (( n >= 2 )); then echo "ok   QEMU got $k (down and up)"; else echo "FAIL QEMU's trace has no $k"; fail=1; fi
done
(( fail == 0 )) || { echo "--- QEMU trace"; head -40 "$T/trace"; }
exit $fail
