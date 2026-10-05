#!/bin/bash
# The final round in one benchmark VM, from the Mac, over SSH.
#   vm.sh TARGET --vm NAME USER@HOST[:PORT] --prepare                 before the round (full update, tools)
#   vm.sh TARGET --vm NAME USER@HOST[:PORT] [--runs 3] [--only LIST] OUT.jsonl
#   vm.sh TARGET --vm NAME USER@HOST[:PORT] --record                  keep the versions now (after a planned change)
#   vm.sh TARGET --vm NAME USER@HOST[:PORT] --desktop [PICTURE]       the quiet desktop (round.sh, before tests and idle)
#   vm.sh TARGET --vm NAME USER@HOST[:PORT] --cleanup [--packages]    after the round
# TARGET: app, app-rc2 (a second OmacVM.app build, OMACVM_APP names it), utm,
# fusion or parallels. NAME: the benchmark VM ("Bench ..."), never the user's
# own; it must be the one VM that runs on that hypervisor. --desktop: Chrome
# closed, notifications dismissed, and PICTURE (the Mac's wallpaper) as the
# background unless the VM already shows the same image (by hash).
# LIST: throughput,vkpeak,geekbench,vkmark,glmark2,browser,webgpu (all by default). FINAL_ROUND_BROWSER: the
# browser tests (default aquarium,basemark).
# The VM runs alone, in full screen on the built-in display (see README.md):
# the round refuses a guest narrower than 3000 px or a Chrome page other than
# 1728x1080 at 2x, and a VM that changed since --prepare (Mesa stays fixed).
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
usage() { sed -n '2,17p' "$0" >&2; exit 2; }
TARGET=${1:-}; shift 2>/dev/null
NAME="" DEST="" OUT="" PICTURE="" MODE=round PKG="" RUNS=3 ONLY=throughput,vkpeak,geekbench,vkmark,glmark2,browser,webgpu
while [ $# -gt 0 ]; do
  case $1 in
    --vm) NAME=$2; shift 2 ;;
    --runs) RUNS=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --prepare) MODE=prepare; shift ;;
    --cleanup) MODE=cleanup; shift ;;
    --record) MODE=record; shift ;;
    --desktop) MODE=desktop; shift; case ${1:-} in /*) PICTURE=$1; shift ;; esac ;;
    --packages) PKG=--packages; shift ;;
    --*) die "unknown option $1" ;;
    *) if [ -z "$DEST" ]; then DEST=$1; else OUT=$1; fi; shift ;;
  esac
done
[ -n "$TARGET" ] && [ -n "$NAME" ] && [ -n "$DEST" ] || usage
[ "$MODE" != round ] || [ -n "$OUT" ] || usage
want() { case ,$ONLY, in *,$1,*) return 0 ;; esac; return 1; }

# KEEP_VM: the target's own processes (by bundle path), not "other VMs".
plist_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown; }
case $TARGET in
  app|app-rc2) KEEP_VM='OmacVM[^/]*\.app/'
       APP=${OMACVM_APP:-$HOME/Applications/OmacVM.app}; [ -d "$APP" ] || APP=/Applications/OmacVM.app
       HV="OmacVM.app $(plist_version "$APP")" ;;
  utm) KEEP_VM='UTM\.app/|com\.apple\.Virtualization'; HV="UTM $(plist_version /Applications/UTM.app)" ;;
  fusion) KEEP_VM='VMware Fusion\.app/'; HV="VMware Fusion $(plist_version "/Applications/VMware Fusion.app")" ;;
  parallels) KEEP_VM='Parallels Desktop\.app/|/prl_'; HV="Parallels Desktop $(prlctl --version 2>/dev/null | awk '{print $3}')" ;;
  *) die "target is app, utm, fusion or parallels" ;;
esac
export KEEP_VM

PORT=22
case $DEST in *:*) PORT=${DEST##*:}; DEST=${DEST%:*} ;; esac
# Never the user's VMs: a benchmark VM by name, and it is what runs.
bench_vm_ok "$NAME" || exit 1
vm_running "${TARGET%-rc2}" "$NAME" "$PORT" || die "start \"$NAME\" (and only it) first"
K=(-i "$HOME/.ssh/omacvm" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
   -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
G=/opt/omacvm-final-round
in_vm() { ssh "${K[@]}" "$DEST" "GLMARK2_VERSION=$GLMARK2_VERSION GLMARK2_DURATION=${GLMARK2_DURATION:-} FINAL_ROUND_BROWSER=${FINAL_ROUND_BROWSER:-aquarium,basemark} bash $G/tests/bench/final-round/guest.sh $*"; }
ssh "${K[@]}" "$DEST" true </dev/null || die "no SSH to $DEST"
copy_tools() {   # the scripts only; $G/state (what prepare found) stays
  COPYFILE_DISABLE=1 tar -C "$REPO" --no-xattrs -cf - src/bench tests/bench |
    ssh "${K[@]}" "$DEST" "rm -rf $G/src $G/tests && mkdir -p $G && tar --no-same-owner -C $G -xf - && chmod -R a+rX $G" ||
    die "copy failed"
}

case $MODE in
  prepare)
    say "$NAME: full system update and the round's tools (before the round, not in it)"
    copy_tools
    in_vm prepare </dev/null || die "prepare failed in the VM (see above)"
    say "$NAME: prepared; let it idle a few minutes before the round"
    exit 0 ;;
  cleanup)
    in_vm cleanup $PKG </dev/null || die "cleanup failed in the VM"
    exit 0 ;;
  record)
    copy_tools
    in_vm record </dev/null || die "record failed in the VM"
    exit 0 ;;
  desktop)
    copy_tools
    sum=""
    if [ -n "$PICTURE" ]; then
      [ -f "$PICTURE" ] || die "no picture $PICTURE"
      sum=$(shasum -a 256 "$PICTURE" | cut -d' ' -f1)
      case $(in_vm desktop "$sum" </dev/null) in
        *'"wallpaper_same_as_mac": true'*) ;;
        *) say "$NAME: the Mac's wallpaper as the background"
           scp -q -P "$PORT" -i "$HOME/.ssh/omacvm" "${K[@]:4}" "$PICTURE" "$DEST:/tmp/${PICTURE##*/}" || die "copying the wallpaper failed"
           in_vm wallpaper "/tmp/${PICTURE##*/}" </dev/null || die "setting the wallpaper failed" ;;
      esac
    fi
    in_vm desktop "$sum" </dev/null
    exit 0 ;;
esac

preflight "$KEEP_VM"
copy_tools
# The VM as prepared (nothing updated since, Mesa the same) and wide enough.
if ! c=$(in_vm check "$MIN_GUEST_WIDTH" </dev/null); then
  [ "${FINAL_ROUND_ALLOW_BUSY:-0}" = 1 ] || die "$NAME is not ready: $c"
  PRELIM=true PRELIM_WHY="${PRELIM_WHY:+$PRELIM_WHY; }VM not ready: $c"; say "marked preliminary: $c"
fi
# Chrome's page as agreed, before the tests that depend on the window.
if want browser; then
  vp=$(in_vm viewport </dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("viewport", ""))' 2>/dev/null)
  if ! viewport_ok "$vp"; then
    [ "${FINAL_ROUND_ALLOW_BUSY:-0}" = 1 ] || die "Chrome's page in $NAME is ${vp:-unknown}, the round needs $VIEWPORT (full screen on the built-in display)"
    PRELIM=true PRELIM_WHY="${PRELIM_WHY:+$PRELIM_WHY; }Chrome page ${vp:-unknown}"
  fi
fi
INFO=$(in_vm info </dev/null); [ -n "$INFO" ] || INFO='{}'
say "$TARGET ($NAME): $HV; $INFO"
# Every line carries the VM's facts.
vrec() {   # test json
  rec "$TARGET" "$1" "$(python3 -c 'import json,sys
r = json.loads(sys.argv[1]); r["vm"] = json.loads(sys.argv[2]); r["hypervisor"] = sys.argv[3]; r["vm_name"] = sys.argv[4]
print(json.dumps(r))' "$2" "$INFO" "$HV" "$NAME")" >/dev/null
}
each() {   # test: one vrec per JSON line on stdin
  local l
  while IFS= read -r l; do case $l in '{'*) vrec "$1" "$l" ;; esac; done
}
want throughput && { say "$TARGET: GPU throughput page x$RUNS (timer, then wall)"; in_vm throughput "$RUNS" </dev/null | each gpu-throughput; }
want vkpeak && { say "$TARGET: vkpeak x$RUNS"; in_vm vkpeak "$RUNS" </dev/null | each vkpeak; }
want geekbench && { say "$TARGET: Geekbench GPU x$RUNS"; in_vm geekbench "$RUNS" </dev/null | each geekbench; }
want vkmark && { say "$TARGET: vkmark x$RUNS"; in_vm vkmark "$RUNS" </dev/null | each vkmark; }
want glmark2 && { say "$TARGET: glmark2 x$RUNS"; in_vm glmark2 "$RUNS" </dev/null | each glmark2; }
want browser && { say "$TARGET: ${FINAL_ROUND_BROWSER:-aquarium,basemark} x$RUNS"; in_vm browser "$RUNS" </dev/null | each browser; }
want webgpu && { say "$TARGET: WebGPU matmul x$RUNS"; in_vm webgpu "$RUNS" </dev/null | each browser; }
in_vm check "$MIN_GUEST_WIDTH" </dev/null >/dev/null || say "warning: $NAME changed during the round (see guest.sh check)"
say "$TARGET: done, $OUT"
