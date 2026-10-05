#!/bin/bash
# A stalled UDP send on the Mac must not freeze the VM (libslirp's sockets are
# non-blocking), and a main loop stall of any cause is logged with its place.
# Usage: test-slirp-udp-stall.sh QEMU [--old]
#   QEMU   a runtime's qemu-system-aarch64 (or OmacVM), signed ad hoc: the test
#          injects a sendto() stall with DYLD_INSERT_LIBRARIES, which the
#          hardened runtime of a release app refuses.
#   --old  the runtime has no fix: the freeze must reproduce (proof the test
#          sees it).
# One idle QEMU without a guest or CPU at a time; nothing leaves the Mac.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
qemu=${1:?usage: test-slirp-udp-stall.sh QEMU [--old]}
work=$(mktemp -d "${TMPDIR:-/tmp}/slirp-stall-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
cc -dynamiclib -O2 -Wall -Werror -o "$work/udp-stall-inject.dylib" "$here/udp-stall-inject.c"
run() { python3 "$here/slirp-udp-stall.py" --qemu "$qemu" --inject "$work/udp-stall-inject.dylib" --case "$1"; }
if [[ ${2:-} == --old ]]; then
  run hang
else
  run fixed
  run watchdog
fi
