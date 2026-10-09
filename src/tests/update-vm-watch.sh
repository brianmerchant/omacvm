#!/bin/bash
# OmacVM.app's Update VM (app/scripts/update-vm.sh) never waits forever: a
# disk that fails (btrfs/ext4 errors or a read-only file system on the VM's
# console or in the apply) or an update past its time stops the VM and says
# why, with the next step. 2026-10-09: a VM copied while it ran came up on a
# MacBook Air with "BTRFS error ... bad tree block start", went read-only,
# and Update VM hung. A stand-in QEMU, ssh and apply in a fixture app; no VM.
#   src/tests/update-vm-watch.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
cleanup() {
  [[ -f $T/qemu.pid ]] && kill "$(cat "$T/qemu.pid")" 2>/dev/null
  rm -f "$(getconf DARWIN_USER_TEMP_DIR)omacvm/$(printf '%s' "$T/VMs/Copied" | shasum | cut -c1-8)".*   # vm_load's pid file
  rm -rf "$T"
}
trap cleanup EXIT
fail=0
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# disk_error on its own.
eval "$(sed -n -e '/^printable()/,/^}/p' -e '/^disk_error()/,/^}/p' "$R/app/scripts/vm-common.sh")"
printf '[    1.2] nvme nvme0: 4/0/0 default/read/poll queues\n[  OK  ] Reached target Graphical Interface.\nRemounting '"'"'/'"'"' read-only with options compress=zstd:1.\n' > "$T/clean.log"
printf '[   3.1] BTRFS error (device nvme0n1p2): bad tree block start, mirror 1 want 30539776 have 0\n[   3.2] BTRFS: error (device nvme0n1p2) in btrfs_run_delayed_refs\n' > "$T/btrfs.log"
printf 'touch: cannot touch '"'"'/usr/local/share/omacvm/x'"'"': Read-only file system\n' > "$T/ro.log"
printf '[  12.0] EXT4-fs error (device vda1): ext4_lookup:1855: inode #2: comm ls: deleted inode referenced\n' > "$T/ext4.log"
expect "a clean boot and shutdown: no disk error" "" "$(disk_error "$T/clean.log")"
expect "btrfs errors" "[   3.1] BTRFS error (device nvme0n1p2): bad tree block start, mirror 1 want 30539776 have 0" "$(disk_error "$T/btrfs.log")"
expect "a read-only file system in the apply" "touch: cannot touch '/usr/local/share/omacvm/x': Read-only file system" "$(disk_error "$T/clean.log" "$T/ro.log")"
expect "ext4 errors" "yes" "$(disk_error "$T/ext4.log" >/dev/null && echo yes)"
expect "no file: no error" "" "$(disk_error "$T/none.log")"

# A fixture app: the real scripts and src/, a stand-in QEMU, ssh and apply.
A=$T/app; mkdir -p "$A/scripts" "$A/runtime/bin" "$A/firmware" "$A/omacvm" "$T/bin"
cp "$R"/app/scripts/*.sh "$A/scripts/"
ln -s "$R/src" "$A/omacvm/src"
: > "$A/firmware/edk2-aarch64-code.fd"
cat > "$A/runtime/bin/OmacVM" <<'QEMU'
#!/bin/bash
# Stand-in QEMU: writes the console its mode asks for, runs until killed.
echo $$ > "$FAKE_DIR/qemu.pid"
while [[ $# -gt 0 ]]; do [[ $1 == -serial ]] && console=${2#file:}; shift; done
: > "$console"
[[ $FAKE_MODE == btrfs ]] && { sleep 2; printf '[    3.1] BTRFS error (device nvme0n1p2): bad tree block start, mirror 1 want 30539776 have 0\n[    3.3] BTRFS: Read-only file system\n' >> "$console"; }
while :; do sleep 1; done
QEMU
cat > "$T/bin/ssh" <<'SSH'
#!/bin/bash
# Stand-in ssh: the VM answers unless it never comes up; poweroff stops QEMU.
[[ $FAKE_MODE == btrfs || $FAKE_MODE == down ]] && exit 255
kill -0 "$(cat "$FAKE_DIR/qemu.pid")" 2>/dev/null || exit 255
# A guest takes a few seconds to power off: the update's watch ends first.
[[ ${*: -1} == "systemctl poweroff" ]] && { (sleep 5; kill "$(cat "$FAKE_DIR/qemu.pid")") & }
exit 0
SSH
cat > "$A/scripts/apply-vm.sh" <<'APPLY'
#!/bin/bash
# Stand-in apply: ok, or hangs (as an apply on a read-only VM did) until QEMU goes.
case $FAKE_MODE in
  ok) echo "==> OmacVM applied"; exit 0 ;;
  # The VM powers off by itself at the end, and the watch ends before the update does.
  ok-off) echo "==> OmacVM applied"; kill "$(cat "$FAKE_DIR/qemu.pid")"; sleep 5; exit 0 ;;
  ro) echo "touch: cannot touch '/usr/local/share/omacvm/x': Read-only file system" ;;
esac
while kill -0 "$(cat "$FAKE_DIR/qemu.pid")" 2>/dev/null; do sleep 1; done
echo "Connection to 127.0.0.1 closed by remote host." >&2
exit 255
APPLY
chmod +x "$A/runtime/bin/OmacVM" "$T/bin/ssh" "$A/scripts/apply-vm.sh"
V=$T/VMs/Copied; mkdir -p "$V"
printf "NAME='Copied'\nCPUS=2\nMEM_MB=4096\nDISK_GB=64\nSSH_PORT=52999\nVM_USER='me'\n" > "$V/vm.env"
: > "$V/disk.img"; : > "$V/efi-vars.fd"; : > "$V/ready"; : > "$T/key"

run() {   # MODE [VAR=VALUE...]: seconds, exit status, the update's ERROR or UPDATED line
  local mode=$1 start out rc; shift
  rm -f "$T/qemu.pid"; start=$(date +%s)
  env PATH="$T/bin:$PATH" FAKE_DIR="$T" FAKE_MODE="$mode" OMACVM_KEY="$T/key" OMACVM_HOST_PORTS= "$@" \
    /bin/bash "$A/scripts/update-vm.sh" "$V" > "$T/out" 2>&1
  rc=$?
  out=$(grep -E '^(ERROR|UPDATED)' "$T/out" | tail -1)
  echo "$(( $(date +%s) - start )) $rc $out"
}
r=$(run btrfs); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "btrfs errors on the console: the update stops with the disk's error" "yes" \
  "$([[ $r == "ERROR: Copied's disk has errors, so the update stopped (the VM says: [    3.1] BTRFS error"* ]] && echo yes || echo "$r")"
expect "... and says what to do" "yes" "$([[ $r == *"shut it down on the Mac it came from and copy it again"* ]] && echo yes)"
expect "... within 40 s, not after the 5 minutes for SSH" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
expect "... and QEMU is gone" "gone" "$(kill -0 "$(cat "$T/qemu.pid")" 2>/dev/null && echo runs || echo gone)"
r=$(run ro); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "a read-only file system in the apply: stops, the disk's error" "yes" \
  "$([[ $r == *"disk has errors"*"Read-only file system"* ]] && echo yes || echo "$r")"
expect "... within 40 s" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
r=$(run hang OMACVM_UPDATE_SECONDS=6); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "an apply that hangs: stopped after the update's time" "yes" \
  "$([[ $r == "ERROR: The update took too long, so it was stopped"* ]] && echo yes || echo "$r")"
expect "... within 40 s" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
r=$(run down OMACVM_UPDATE_SECONDS=6); s=${r%% *}; r=${r#* }; rc=${r%% *}; r=${r#* }
expect "a VM that never comes up: stopped after the update's time" "yes" \
  "$([[ $r == "ERROR: The update took too long"* ]] && echo yes || echo "$r")"
expect "... within 40 s" "yes" "$( (( s < 40 )) && echo yes || echo "$s s")"
expect "a stopped update fails (exit 1)" "1" "$rc"
r=$(run ok); r=${r#* }; rc=${r%% *}; r=${r#* }
expect "a good update: no false alarm" "UPDATED Copied" "$r"
expect "... and exits 0" "0" "$rc"
r=$(run ok-off); r=${r#* }; rc=${r%% *}; r=${r#* }
expect "the VM off before the update ends: still UPDATED, exit 0 (the watch had ended)" "0 UPDATED Copied" "$rc $r"
exit $fail
