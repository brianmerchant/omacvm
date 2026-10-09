#!/bin/bash
# Bring an existing OmacVM.app VM up to this app's OmacVM: start it without a
# window, apply OmacVM (as at the end of a build), shut it down. For VMs made
# by an older app: replacing the app does not touch the VM, and a VM from
# before 3.0.0 has no control centre that could ask for the update.
#   update-vm.sh VM_DIR
# Progress lines as create-vm.sh ("==>", "STEP n/N"). Exit 0 = updated and
# powered off. Nothing is deleted: a failed apply leaves the VM as it was
# (omacvm apply rolls its own steps back), and it starts as before.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"

vm_load "${1:?usage: update-vm.sh VM_DIR}"
[[ -f $VM_DIR/disk.img && -f $VM_DIR/efi-vars.fd && -e $VM_DIR/ready ]] || die "$NAME is not a finished VM"
# QEMU names the disk on its command line: one that runs from here or from the
# command line (omacvm start) must not get a second QEMU on the same disk.
if ps -x -U "$(id -u)" -o args= | grep -v grep | grep -qF -- "file=$(qe "$VM_DIR/disk.img"),"; then
  die "$NAME runs: shut it down, then update it"
fi

STEPS=3
step() { echo "STEP $1/$STEPS $2"; }
# However this ends (also the app quitting): the VM shuts down cleanly first,
# it has the user's files.
stop_vm() {
  qemu_running || return 0
  vssh "systemctl poweroff" < /dev/null 2>/dev/null || true
  qemu_wait_exit 90 || qemu_quit
}
WATCH=
trap '[[ -z $WATCH ]] || kill "$WATCH" 2>/dev/null; stop_vm' EXIT

# Never waits forever: a disk that fails (the console or the apply shows
# btrfs/ext4 errors or a read-only file system) or an update that takes more
# than OMACVM_UPDATE_MINUTES (default 40; OMACVM_UPDATE_SECONDS for tests)
# stops the VM at once; the steps then fail and say why (stopped_why).
REASON=$LOG/update-stopped
rm -f "$REASON"
: > "$LOG/omacvm-update.log"   # the last update's lines are not this one's
watch_update() {
  local limit=${OMACVM_UPDATE_SECONDS:-$((${OMACVM_UPDATE_MINUTES:-40} * 60))} t=0 line
  while qemu_running; do
    if line=$(disk_error "$LOG/update-console.log" "$LOG/omacvm-update.log"); then
      printf 'disk %s\n' "$line" > "$REASON"
      qemu_quit
      return
    fi
    if (( t >= limit )); then
      echo "time" > "$REASON"
      if vssh "systemctl poweroff" < /dev/null 2>/dev/null; then qemu_wait_exit 60 || qemu_quit; else qemu_quit; fi
      return
    fi
    sleep 3; t=$((t + 3))
  done
}
stopped_why() {   # the plain error after a step failed, with the next step
  local r; r=$(cat "$REASON" 2>/dev/null)
  case $r in
    disk*) echo "$NAME's disk has errors, so the update stopped (the VM says: ${r#disk }). A VM copied while it ran has a damaged disk: shut it down on the Mac it came from and copy it again. Else start it and look at its disk (log: $LOG/update-console.log)." ;;
    time) echo "The update took too long, so it was stopped (log: $LOG/omacvm-update.log). Start the VM and see whether it comes up." ;;
    *) echo "$1" ;;
  esac
}

step 1 "Starting $NAME without a window"
qemu_headless update "${QEMU_UEFI[@]}" -drive "$DISK_OPT" -device nvme,serial=omacvm,drive=disk,bootindex=0
watch_update &
WATCH=$!
wait_ssh 300 || die "$(stopped_why "$NAME did not come up within 5 minutes (log: $LOG/update-console.log). Start it from the app to see what it shows.")"

step 2 "Updating OmacVM in the VM and on the Mac"
run_logged "$LOG/omacvm-update.log" "$HERE/apply-vm.sh" "$VM_DIR" ||
  die "$(stopped_why "OmacVM did not update (log: $LOG/omacvm-update.log); the VM starts as before")"
[[ -s $REASON ]] && die "$(stopped_why "")"

step 3 "Shutting down"
stop_vm
echo "UPDATED $NAME"
