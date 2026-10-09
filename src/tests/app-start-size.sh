#!/bin/bash
# A VM copied from a bigger Mac (16 CPUs, 48 GB in vm.env onto an 8 GB
# MacBook Air) starts at this Mac's Best tier, and vm.env keeps its values.
# The app passes the size to its scripts (Creator.update ->
# OMACVM_START_CPUS / OMACVM_START_MEM_MB -> vm_load in
# app/scripts/vm-common.sh); the rule itself (ResourceLimits.startSize) is in
# `swift run window-tests`. Fixture folder only, no VM.
#   src/tests/app-start-size.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
mkdir -p "$T/VM"
printf "NAME='Big'\nCPUS=16\nMEM_MB=49152\nDISK_GB=128\nSSH_PORT=52222\nVM_USER='me'\n" > "$T/VM/vm.env"
cp "$T/VM/vm.env" "$T/vm.env.before"
: > "$T/key"   # vm_load makes the SSH key when it is missing
size() {   # [VAR=VALUE...]: CPUS MEM_MB after vm_load
  env KEY="$T/key" "$@" /bin/bash -c 'die() { echo "die: $*"; exit 1; }; qe() { printf "%s" "$1"; }
    eval "$(sed -n "/^vm_load()/,/^}/p" "$1")"; vm_load "$2" >/dev/null; echo "$CPUS $MEM_MB"' _ "$R/app/scripts/vm-common.sh" "$T/VM"
}
expect "no size from the app: vm.env's" "16 49152" "$(size)"
expect "the app's size for this run" "8 4096" "$(size OMACVM_START_CPUS=8 OMACVM_START_MEM_MB=4096)"
expect "only the memory" "16 4096" "$(size OMACVM_START_MEM_MB=4096)"
expect "not a number: vm.env's" "16 49152" "$(size 'OMACVM_START_CPUS=8; rm -rf /' OMACVM_START_MEM_MB=4g)"
expect "zero or too small: vm.env's" "16 49152" "$(size OMACVM_START_CPUS=0 OMACVM_START_MEM_MB=512)"
expect "vm.env is not changed" "same" "$(cmp -s "$T/vm.env.before" "$T/VM/vm.env" && echo same || echo changed)"
exit $fail
