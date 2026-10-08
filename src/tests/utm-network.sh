#!/bin/bash
# UTM's shared network not on 192.168.64.0/24: vm_network_ok (src/lib/mac.sh)
# refuses with what to do, and omacvm build checks it as soon as the live
# installer has its address (before the install), not only in step 5.
# No VM, no UTM.
#   src/tests/utm-network.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}
chk() { bash -c 'source "$1/src/lib/mac.sh"; vm_network_ok utm "$2"' _ "$R" "$1" 2>&1; echo "rc=$?"; }

out=$(chk 192.168.64.7)
expect "192.168.64.x: ok, nothing said" "rc=0" "$out"
out=$(chk 192.168.78.2)
expect "192.168.78.x: refused" yes "$([[ $out == *rc=1 ]] && echo yes || echo "$out")"
expect "it names the address and the range OmacVM needs" yes \
  "$([[ $out == *"at 192.168.78.2, outside UTM's default shared network 192.168.64.0/24"* ]] && echo yes || echo "$out")"
expect "it says what to do and why it can happen" yes \
  "$([[ $out == *'"Shared Network" mode'* && $out == *"another VM network on this Mac"* ]] && echo yes || echo "$out")"

# build.sh: UTM's live installer address is checked before step 3 (the install).
B=$R/src/cmd/build.sh
ip=$(grep -n 'utm_ip "\$VM" 300' "$B" | head -1 | cut -d: -f1)
ok=$(grep -n 'vm_network_ok utm "\$IP"' "$B" | head -1 | cut -d: -f1)
st=$(grep -n 'step "Arch Linux ARM onto' "$B" | head -1 | cut -d: -f1)
expect "build.sh checks UTM's network right after the live installer's address" yes \
  "$([[ -n $ip && -n $ok && -n $st ]] && (( ip < ok && ok < st )) && echo yes || echo "utm_ip ${ip:-?}, check ${ok:-none}, step 3 ${st:-?}")"
expect "and stops as needing a person (exit 3)" yes \
  "$(sed -n "${ok:-1}p" "$B" | grep -q 'needs_person' && echo yes || echo no)"
bash -n "$B"; expect "build.sh parses" 0 $?

(( fail )) && { echo "utm-network: FAILED"; exit 1; }
echo "utm-network: all ok"
