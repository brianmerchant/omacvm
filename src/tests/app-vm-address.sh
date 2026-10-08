#!/bin/bash
# An OmacVM.app VM's address (src/lib/app.sh app_ip): on the fast network
# (vmnet) from the MAC address the running QEMU has, not only from the
# fast-network file, which says how the NEXT start goes: turning the fast
# network off removes it while the VM keeps running on vmnet, and the VM was
# then "not set up" for the Bridge and the control centre until a restart.
# Without vmnet's address (the app moved it to QEMU's own network), the SSH
# port on 127.0.0.1. Turning the fast network on or off while the VM runs is
# for its next start only (app_fast_network_wish). Stand-ins: a perl "QEMU"
# with the app's command line that
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
# A free port (not a random one: a VM on this Mac or another copy of this test
# on another CI runner may hold it, then the stand-in below cannot listen).
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
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

# 3b. Turning the fast network off while the VM runs on it (the control
#     centre, omacvm disable, Update VM): only the next start changes. The
#     address stays the running QEMU's, the service stays (a VM runs on it).
out=$(app_fast_network_wish "$D" off)
check "off while running on vmnet: said so" "fast network: off from the VM's next start; it keeps the fast network until it shuts down" "$out"
check "off while running on vmnet: the next start's file is gone" "no" "$([[ -e $D/fast-network ]] && echo yes || echo no)"
check "off while running on vmnet: still the vmnet address" 192.168.77.9 "$(app_ip Work)"
check "off while running on vmnet: it runs on the fast network (keep the service)" yes "$(app_any_on_vmnet && echo yes || echo no)"
app_fast_network_wish "$D" off >/dev/null; check "off again: nothing to change" 1 "$?"
# ... and on again while it still runs there: the running card's MAC (its address stays).
out=$(app_fast_network_wish "$D" on)
check "on again while running on vmnet: said so" "fast network: on (the VM runs on it now)" "$out"
check "on again while running on vmnet: the running QEMU's MAC for the next start" "mac=$QMAC" "$(cat "$D/fast-network")"
check "on again: the address stays" 192.168.77.9 "$(app_ip Work)"
echo "mac=52:54:00:11:22:33" > "$D/fast-network"

# 4. vmnet gone (no lease): the app moved the VM to QEMU's own network, SSH on 127.0.0.1.
LEASES=""
check "no vmnet address: 127.0.0.1 and its SSH port" "127.0.0.1:$PORT" "$(app_ip Work)"

# 5. QEMU's own network from the start.
echo "slirp off" > "$D/logs/network"; rm -f "$D/fast-network"
check "user network: 127.0.0.1 and its SSH port" "127.0.0.1:$PORT" "$(app_ip Work)"

# 5b. On QEMU's own network (no fast network card): turning it on is for the
#     next start; the address is 127.0.0.1's, never from the file's MAC.
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null
perl -MIO::Socket::INET -e '$s = IO::Socket::INET->new(LocalAddr => "127.0.0.1", LocalPort => $ARGV[0], Listen => 1, ReuseAddr => 1) or die; sleep 60' \
  "$PORT" -drive "if=none,id=disk,file=$D/disk.img,format=raw,cache=writeback" \
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$PORT-:22" -device "virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,romfile=" &
QPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do lsof -nP -a -p "$QPID" -iTCP@127.0.0.1:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && break; sleep 0.3; done
LEASES="$QMAC 192.168.77.9
52:54:00:dd:ee:ff 192.168.77.20"
out=$(app_fast_network_wish "$D" on)
check "on while running on the user network: from the next start" "fast network: on from the VM's next start (shut it down, then start it again); it keeps QEMU's own network until then" "$out"
m=$(sed -n 's/^mac=//p' "$D/fast-network")
check "on while running on the user network: a new MAC of OmacVM's range" yes "$([[ $m =~ ^52:54:00(:[0-9a-f]{2}){3}$ && $m != "$QMAC" ]] && echo yes || echo no)"
check "the running QEMU has no fast network card: no MAC from the file" "" "$(app_vm_mac "$D" "$QPID")"
echo "mac=52:54:00:dd:ee:ff" > "$D/fast-network"; echo vmnet > "$D/logs/network"   # a stale record and a leased MAC in the file
check "a stale vmnet record, the file's MAC leased: still 127.0.0.1 (the running QEMU counts)" "127.0.0.1:$PORT" "$(app_ip Work)"
echo "slirp off" > "$D/logs/network"
check "on the user network: it does not run on the fast network" no "$(app_any_on_vmnet && echo yes || echo no)"
check "why no address: QEMU's SSH port" "QEMU does not answer on its SSH port 127.0.0.1:$PORT (still starting?)" "$(app_no_address "$D")"
echo "vmnet-down the fast network stopped working" > "$D/logs/network"
check "why no address: the fast network is down" "its fast network is down: the fast network stopped working" "$(app_no_address "$D")"
echo "slirp off" > "$D/logs/network"

# 6. Stopped: no address.
kill "$QPID" 2>/dev/null; wait "$QPID" 2>/dev/null; QPID=""
check "stopped: no address" "" "$(app_ip Work)"
check "stopped: why there is no address" "its QEMU is not running" "$(app_no_address "$D")"
check "stopped: off is just off" "fast network: off" "$(app_fast_network_wish "$D" off)"
check "stopped: on from the next start" "fast network: on from the VM's next start" "$(app_fast_network_wish "$D" on)"

# 7. "Another SSH host key" (omacvm vms' why) only from a key of the type
#    remembered: a scan cut short by a busy VM (only its RSA key) tells nothing.
OMA_PIN=$T/pin; echo "omacvm-vm ssh-ed25519 AAAAgood" > "$OMA_PIN"
SCAN=""
ssh-keyscan() { printf '%s' "$SCAN"; }
SCAN=$'[127.0.0.1]:1 ssh-rsa AAAArsa\n'
check "scan with only another key type: not 'changed'" same "$(hostkey_changed 127.0.0.1:1 && echo changed || echo same)"
SCAN=$'[127.0.0.1]:1 ssh-rsa AAAArsa\n[127.0.0.1]:1 ssh-ed25519 AAAAgood\n'
check "the remembered key: same" same "$(hostkey_changed 127.0.0.1:1 && echo changed || echo same)"
SCAN=$'[127.0.0.1]:1 ssh-ed25519 AAAAother\n'
check "another key of the remembered type: changed" changed "$(hostkey_changed 127.0.0.1:1 && echo changed || echo same)"
SCAN=""
check "no answer: not 'changed'" same "$(hostkey_changed 127.0.0.1:1 && echo changed || echo same)"
unset -f ssh-keyscan

# 8. Why SSH did not get in (omacvm vms' why, the Bridge's "the Mac cannot reach
#    this VM: ..."): from ssh's own messages, never a second connection. Each
#    unauthenticated one (ssh-keyscan opens several) counts against the Mac in
#    sshd's PerSourcePenalties: the 2026-10-07 mini e2e lost SSH to its VM for
#    minutes that way (vms --json scanned each unreachable VM, the Bridge asked
#    every few seconds).
E=$T/ssh-err
why() { printf '%s\n' "$1" > "$E"; ssh_failure_why 127.0.0.1:52501 "$E"; }
check "another host key" "hostkey 127.0.0.1:52501 answers with another SSH host key" \
  "$(why $'@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\nHost key verification failed.')"
check "the key refused" "OmacVM's SSH key did not get in at 127.0.0.1:52501" "$(why 'root@127.0.0.1: Permission denied (publickey).')"
check "nothing listens" "nothing takes SSH at 127.0.0.1:52501 (the VM is starting, or its SSH stopped)" \
  "$(why 'ssh: connect to host 127.0.0.1 port 52501: Connection refused')"
check "sshd turns the Mac away (PerSourcePenalties)" \
  "SSH at 127.0.0.1:52501 closed the connection (the VM is busy or starting, or its SSH turns the Mac away for a while after many tries)" \
  "$(why 'kex_exchange_identification: read: Connection reset by peer')"
check "no answer" "SSH at 127.0.0.1:52501 did not answer (the VM is busy, or its network is down)" \
  "$(why 'ssh: connect to host 127.0.0.1 port 52501: Operation timed out')"
check "something else: its first line" "SSH to 127.0.0.1:52501 did not get in: Bad owner or permissions on /x/config" \
  "$(why 'Bad owner or permissions on /x/config')"
: > "$E"
check "nothing said (sshd closed it at once: PerSourcePenalties, OpenSSH 10.5 in the guest)" \
  "SSH at 127.0.0.1:52501 closed the connection (the VM is busy or starting, or its SSH turns the Mac away for a while after many tries)" \
  "$(ssh_failure_why 127.0.0.1:52501 "$E")"
# A real ssh to a port nobody takes.
ssh -o BatchMode=yes -o ConnectTimeout=3 -o LogLevel=ERROR -p 1 root@127.0.0.1 true 2> "$E" < /dev/null
check "a real refused connection" "nothing takes SSH at 127.0.0.1:1 (the VM is starting, or its SSH stopped)" "$(ssh_failure_why 127.0.0.1:1 "$E")"
check "omacvm vms never scans a VM's host keys" 0 "$(grep -c 'ssh-keyscan\|hostkey_changed' "$R/src/cmd/vms.sh")"
# wait_ssh (apply, build, check: waiting for a VM that boots) tells another
# host key from ssh's own words, and never scans the keys on each try.
SCANS=$T/scans; : > "$SCANS"
ssh-keyscan() { echo scan >> "$SCANS"; }
hostkey_error() { echo "hostkey_error" >&2; }
gssh() { echo "Host key verification failed." >&2; return 255; }
rc=0; (wait_ssh 127.0.0.1:1 30) 2>/dev/null || rc=$?
check "wait_ssh: another host key -> 3 at once" 3 "$rc"
gssh() { echo "ssh: connect to host 127.0.0.1 port 1: Connection refused" >&2; return 255; }
die() { echo "die: $*" >&2; exit 1; }
rc=0; (wait_ssh 127.0.0.1:1 0) 2>/dev/null || rc=$?
check "wait_ssh: no SSH -> it gives up (die)" 1 "$rc"
check "wait_ssh: no key scans" 0 "$(wc -l < "$SCANS" | tr -d ' ')"
unset -f ssh-keyscan gssh

exit $fail
