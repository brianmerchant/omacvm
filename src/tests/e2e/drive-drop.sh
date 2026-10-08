#!/bin/bash
# OmacVM.app when the drive with a running VM's folder drops off, on a real
# test app (OmacVM Test.app, org.omacvm.app.test) and a firmware-only VM on a
# sparse image "OmacVM-DD". Hidden (OMACVM_COCOA_HIDDEN), the image mounted
# -nobrowse. The app's stderr says what its window would show ("drive: ...").
# Hold the Mac's test-app launcher slot. Never the person's VM: the run stops
# unless the VM it starts is the test VM on the image (test-vms.sh).
#   D=WORKDIR src/tests/e2e/drive-drop.sh setup       image + VM DD-fw, the test app's settings saved
#   D=WORKDIR src/tests/e2e/drive-drop.sh run MODE    start DD-fw from WORKDIR/MODE/OmacVM Test.app, drop
#                                                     the drive by force, watch, reattach; then launch with
#                                                     the drive missing and plug it back
#   D=WORKDIR src/tests/e2e/drive-drop.sh clean       detach, delete the image, settings back
# WORKDIR may have spaces (a Mac's home on "Macintosh SSD").
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/test-vms.sh"
D=${D:?D: the work folder (WORKDIR/base and WORKDIR/new hold the apps)}
IMG=$D/dd.sparseimage
VOL=/Volumes/OmacVM-DD
VM=${VM:-DD-fw}
DOM=${OMACVM_TEST_DOMAIN:-org.omacvm.app.test}
SAVED=$D/saved
TS="$HOME/Library/Application Support/omacvm-test"

attach() { hdiutil attach -quiet -nobrowse "$IMG" && [[ -d $VOL/VMs ]]; }

case ${1:-} in
setup)
  mkdir -p "$D"
  [[ -f $IMG ]] || hdiutil create -quiet -size 200g -type SPARSE -fs APFS -volname OmacVM-DD "$IMG"
  [[ -d $VOL ]] || hdiutil attach -quiet -nobrowse "$IMG"
  mkdir -p "$VOL/VMs/$VM/logs"
  ( cd "$VOL/VMs/$VM" || exit 1
    [[ -f disk.img ]] || mkfile -n 2g disk.img
    [[ -f efi-vars.fd ]] || mkfile -n 64m efi-vars.fd
    printf "NAME='%s'\nCPUS=2\nMEM_MB=2048\nDISK_GB=2\nSSH_PORT=52296\nVM_USER='dd'\nFEATURES=''\n" "$VM" > vm.env
    echo opengl > graphics; touch ready ) || exit 1
  # The test app's settings as they are now: clean puts them back.
  e2e_settings_save "$DOM" "$SAVED" vmsRoot skipInstallPaths || exit 1
  if [[ ! -f $SAVED/domain ]]; then
    defaults read "$DOM" >/dev/null 2>&1 && echo domain > "$SAVED/domain" || echo nodomain > "$SAVED/domain"
    cp -p "$TS/cli" "$SAVED/test-cli" 2>/dev/null
    shasum "$HOME/Library/Application Support/omacvm/cli" > "$SAVED/prod-cli.sha" 2>/dev/null
  fi
  defaults write "$DOM" vmsRoot "$VOL/VMs"
  for m in base new; do defaults write "$DOM" skipInstallPaths -array-add "$D/$m/OmacVM Test.app"; done
  ls -ls "$VOL/VMs/$VM"; cat "$VOL/VMs/$VM/vm.env"
  ;;
run)
  MODE=${2:?run base|new}
  APP="$D/$MODE/OmacVM Test.app"
  OUT=$D/out/$MODE; rm -rf "$OUT"; mkdir -p "$OUT"
  log() { echo "$(date +%H:%M:%S) $*" | tee -a "$OUT/run.log"; }
  ax() { log "app stderr ($2):"; grep -h "drive:" "$OUT"/app*.stderr 2>/dev/null | sed 's/^/      /' | tee -a "$OUT/run.log"; }
  lpid() { pgrep -f "^$APP/Contents/MacOS/OmacVM( |\$)" | head -1; }
  qpid() { pgrep -f "$VOL/VMs/$VM/disk.img" | head -1; }
  [[ -d $VOL/VMs/$VM ]] || attach || { log "image not attached"; exit 1; }
  # Only the test VM on the image, through the test app's own VMs folder.
  g=$(e2e_vm_guard "$DOM" "$VM") || { log "guard: not started"; exit 3; }
  [[ $g == "$VOL/VMs/$VM" ]] || { log "guard: $VM is at $g, not on the image: not started"; exit 3; }
  touch "$OUT/marker"
  log "start $VM from $MODE"
  open -n -g --env OMACVM_COCOA_HIDDEN=1 --stderr "$OUT/app.stderr" "$APP" --args --start --vm "$VM"
  q=""; for _ in $(seq 60); do q=$(qpid); [[ -n $q ]] && break; sleep 1; done
  l=$(lpid)
  [[ -n $q ]] || { log "QEMU did not start"; ax "$l" nostart; exit 1; }
  log "QEMU $q, launcher $l; guest runs ${BOOT:-25} s"
  sleep "${BOOT:-25}"
  log "console.log $(stat -f %z "$VOL/VMs/$VM/logs/console.log" 2>/dev/null) bytes; drop the drive (detach -force)"
  t0=$(date +%s)
  hdiutil detach -force "$VOL" > "$OUT/detach.txt" 2>&1; log "detach rc=$? after $(( $(date +%s) - t0 )) s"
  qgone=""; lgone=""
  for _ in $(seq 45); do
    [[ -z $qgone ]] && ! kill -0 "$q" 2>/dev/null && { qgone=$(( $(date +%s) - t0 )); log "QEMU ended $qgone s after the drop began"; }
    [[ -z $lgone ]] && ! kill -0 "$l" 2>/dev/null && { lgone=$(( $(date +%s) - t0 )); log "LAUNCHER ENDED $lgone s after the drop began"; }
    sleep 1
  done
  [[ -n $qgone ]] || log "QEMU STILL RUNS 45 s after the drop"
  [[ -n $lgone ]] || log "launcher still runs"
  log "crash reports since start:"
  find "$HOME/Library/Logs/DiagnosticReports" -newer "$OUT/marker" -type f 2>/dev/null | tee -a "$OUT/run.log" |
    while IFS= read -r f; do cp "$f" "$OUT/"; done
  log "/Volumes now: $(ls /Volumes | tr '\n' '|')"
  [[ -e $VOL ]] && log "WRONG PLACE? $VOL exists: $(ls -la "$VOL" 2>&1 | head -5 | tr '\n' '|')"
  log "app stderr:"; sed 's/^/      /' "$OUT/app.stderr" | tail -15 | tee -a "$OUT/run.log"
  [[ -z $lgone ]] && ax "$l" after-drop
  log "drive back (attach)"
  attach; sleep 6
  [[ -z $lgone ]] && ax "$l" drive-back
  log "qemu.log tail:"; tail -8 "$VOL/VMs/$VM/logs/qemu.log" 2>/dev/null | sed 's/^/      /' | tee -a "$OUT/run.log"
  kill -0 "$q" 2>/dev/null && { log "killing my QEMU $q"; kill "$q"; sleep 3; kill -9 "$q" 2>/dev/null; }
  kill -0 "$l" 2>/dev/null && { kill "$l"; sleep 2; }
  # The app opened with the drive missing (no --vm: it shows its VMs folder's drive as missing), then plugged in.
  log "launch with the drive missing"
  hdiutil detach -quiet "$VOL" || hdiutil detach -quiet -force "$VOL"
  [[ $(e2e_vms_root "$DOM") == "$VOL/VMs" ]] || { log "guard: the test app's VMs folder is not the image's: not launched"; exit 3; }
  open -n -g --env OMACVM_COCOA_HIDDEN=1 --stderr "$OUT/app2.stderr" "$APP"
  sleep 8; l=$(lpid); ax "$l" launch-missing
  log "drive plugged in"
  attach; sleep 6; ax "$l" launch-plugged
  [[ -n $l ]] && kill "$l" 2>/dev/null; sleep 2
  log "done"
  ;;
clean)
  hdiutil detach -quiet "$VOL" 2>/dev/null || hdiutil detach -quiet -force "$VOL" 2>/dev/null
  rm -f "$IMG"
  rc=0
  e2e_settings_restore "$DOM" "$SAVED" vmsRoot skipInstallPaths || rc=1
  # A domain the run made goes again, but only when everything saved came back.
  [[ $rc == 0 && $(cat "$SAVED/domain" 2>/dev/null) == nodomain ]] && defaults delete "$DOM" 2>/dev/null
  [[ -f $SAVED/test-cli ]] && cp -p "$SAVED/test-cli" "$TS/cli"
  [[ -f $SAVED/prod-cli.sha ]] && shasum -c "$SAVED/prod-cli.sha" >/dev/null 2>&1 && echo "production cli untouched"
  echo "vmsRoot now: $(defaults read "$DOM" vmsRoot 2>&1)"
  (( rc == 0 )) && rm -f "$SAVED/domain" "$SAVED/test-cli" "$SAVED/prod-cli.sha"
  exit $rc
  ;;
*) echo "usage: D=WORKDIR drive-drop.sh setup | run base|new | clean" >&2; exit 2 ;;
esac
