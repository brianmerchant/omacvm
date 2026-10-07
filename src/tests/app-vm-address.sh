#!/bin/bash
# An OmacVM.app VM's address (src/lib/app.sh app_ip): on the fast network
# (vmnet) from the MAC address the running QEMU has, not only from the
# fast-network file, which says how the NEXT start goes: turning the fast
# network off removes it while the VM keeps running on vmnet, and the VM was
# then "not set up" for the Bridge and the control centre until a restart.
# Without vmnet's address (the app moved it to QEMU's own network), the SSH
# port on 127.0.0.1. Stand-ins: a perl "QEMU" with the app's command line that
# listens on 127.0.0.1, macOS's DHCP leases as a function. No VM, no app.
#   src/tests/app-vm-address.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
QPID=""
trap '[[ -n $QPID ]] && kill "$QPID" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
fail=0
check() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

export HOME=$T/home
B=$T/bin
mkdir -p "$HOME" "$B"
printf '#!/bin/bash\nexit 1\n' > "$B/defaults"   # no app settings: the VMs folder is ~/OmacVM
chmod +x "$B/defaults"
export PATH="$B:$PATH"
unset OMACVM_TEST_IDENTITY OMACVM_APP_ID

D=$HOME/OmacVM/Work
mkdir -p "$D/logs"
: > "$D/disk.img"
PORT=$((52000 + RANDOM % 900))
printf "NAME='Work'\nSSH_PORT=%s\n" "$PORT" > "$D/vm.env"
QMAC=52:54:00:aa:bb:cc

# The app's QEMU on vmnet (Runner.swift): the disk and the NIC on netdev "fast".
# It listens on 127.0.0.1:PORT like the user network's hostfwd once the app
# moved the VM there.
perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ARGV[0], Listen => 1, ReuseAddr => 1) or die; sleep 60' \
  "$PORT" -drive "if=none,id=disk,file=$D/disk.img,format=raw,cache=writeback" \
  -netdev "stream,id=fast,server=off,reconnect-ms=1000,addr.type=unix,addr.path=/var/run/org.omacvm.netd.sock" \
  -device "virtio-net-pci,id=nic0,netdev=fast,mac=$QMAC,romfile=" &
QPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do lsof -nP -a -p "$QPID" -iTCP@127.0.0.1:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.3; done

source "$R/src/lib/mac.sh"
source "$R/src/lib/vm.sh"
# macOS's DHCP server's leases (/var/db/dhcpd_leases): one for the QEMU's MAC.
LEASES="$QMAC 192.168.77.9"
lease_ip() { awk -v m="$1" '$1 == m { print $2 }' <<<"$LEASES"; }

check "the stand-in is the VM's QEMU" "$QPID" "$(app_pid_dir "$D")"

# 1. Running on vmnet, its fast-network file gone (the fast network turned off
#    while it ran: from its next start): the address from QEMU's own MAC.
echo vmnet > "$D/logs/network"
check "MAC from the running QEMU" "$QMAC" "$(app_vm_mac "$D" "$QPID")"
check "fast network off while it runs: vmnet address" 192.168.77.9 "$(app_ip Work)"

# 2. The file names another MAC than the running QEMU (written for the next
#    start): the running one counts.
echo "mac=52:54:00:11:22:33" > "$D/fast-network"
check "file differs: the running QEMU's MAC" "$QMAC" "$(app_vm_mac "$D" "$QPID")"
check "file differs: vmnet address" 192.168.77.9 "$(app_ip Work)"

# 3. Not running: the file's MAC (what the next start takes).
check "not running: the file's MAC" 52:54:00:11:22:33 "$(app_vm_mac "$D")"

# 4. vmnet gone (no lease): the app moved the VM to QEMU's own network, SSH on 127.0.0.1.
LEASES=""
check "no vmnet address: 127.0.0.1 and its SSH port" "127.0.0.1:$PORT" "$(app_ip Work)"

# 5. QEMU's own network from the start.
echo "slirp off" > "$D/logs/network"; rm -f "$D/fast-network"
check "user network: 127.0.0.1 and its SSH port" "127.0.0.1:$PORT" "$(app_ip Work)"

# 6. Stopped: no address.
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
check "stopped: no address" "" "$(app_ip Work)"

exit $fail
