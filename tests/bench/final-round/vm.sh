#!/bin/bash
# The final round in one VM, from the Mac, over SSH.
#   vm.sh app|utm|fusion|parallels USER@HOST[:PORT] [--runs 3] [--only throughput,vkpeak,browser,glmark2] OUT.jsonl
# The VM runs alone, in full screen on the built-in display (see README.md).
# Copies src/bench and tests/bench into the VM, installs glmark2 and
# vkpeak's build tools with pacman, then runs each test. Results go to OUT,
# one JSON line per run, with the VM's and the Mac's facts.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/common.sh"
TARGET=${1:-}; DEST=${2:-}; shift 2 2>/dev/null
RUNS=3; ONLY=throughput,vkpeak,browser,glmark2
while [ "${1:-}" != "${1#--}" ]; do
  case $1 in
    --runs) RUNS=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
OUT=${1:-}
[ -n "$TARGET" ] && [ -n "$DEST" ] && [ -n "$OUT" ] || { sed -n '2,7p' "$0" >&2; exit 2; }
want() { case ,$ONLY, in *,$1,*) return 0 ;; esac; return 1; }

# KEEP_VM: the VM app's own processes (by bundle path), not "other VMs".
plist_version() { defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown; }
case $TARGET in
  app) KEEP_VM='OmacVM[^/]*\.app/'
       APP=${OMACVM_APP:-$HOME/Applications/OmacVM.app}; [ -d "$APP" ] || APP=/Applications/OmacVM.app
       HV="OmacVM.app $(plist_version "$APP")" ;;
  utm) KEEP_VM='UTM\.app/|com\.apple\.Virtualization'; HV="UTM $(plist_version /Applications/UTM.app)" ;;
  fusion) KEEP_VM='VMware Fusion\.app/'; HV="VMware Fusion $(plist_version "/Applications/VMware Fusion.app")" ;;
  parallels) KEEP_VM='Parallels Desktop\.app/'; HV="Parallels Desktop $(prlctl --version 2>/dev/null | awk '{print $3}')" ;;
  *) die "target is app, utm, fusion or parallels" ;;
esac
export KEEP_VM

PORT=22
case $DEST in *:*) PORT=${DEST##*:}; DEST=${DEST%:*} ;; esac
K=(-i "$HOME/.ssh/omacvm" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
   -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
G=/opt/omacvm-final-round
in_vm() { ssh "${K[@]}" "$DEST" "GLMARK2_VERSION=$GLMARK2_VERSION bash $G/tests/bench/final-round/guest.sh $*"; }

preflight "$KEEP_VM"
ssh "${K[@]}" "$DEST" true </dev/null || die "no SSH to $DEST"
say "$TARGET: tools into the VM"
COPYFILE_DISABLE=1 tar -C "$REPO" --no-xattrs -cf - src/bench tests/bench |
  ssh "${K[@]}" "$DEST" "rm -rf $G && mkdir -p $G && tar --no-same-owner -C $G -xf - && chmod -R a+rX $G" || die "copy failed"
in_vm prepare </dev/null || die "prepare failed in the VM (pacman, or Chrome missing)"
INFO=$(in_vm info </dev/null); [ -n "$INFO" ] || INFO='{}'
say "$TARGET: $HV; $INFO"
# Every line carries the VM's facts.
vrec() {   # test json
  rec "$TARGET" "$1" "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); r["vm"]=json.loads(sys.argv[2]); r["hypervisor"]=sys.argv[3]; print(json.dumps(r))' "$2" "$INFO" "$HV")" >/dev/null
}
each() {   # test: one vrec per JSON line on stdin
  local l
  while IFS= read -r l; do case $l in '{'*) vrec "$1" "$l" ;; esac; done
}
want throughput && { say "$TARGET: GPU throughput page x$RUNS"; in_vm throughput "$RUNS" </dev/null | each gpu-throughput; }
want vkpeak && { say "$TARGET: vkpeak x$RUNS"; in_vm vkpeak "$RUNS" </dev/null | each vkpeak; }
want browser && { say "$TARGET: Aquarium 30k + Basemark Web 3.0 x$RUNS"; in_vm browser "$RUNS" </dev/null | each browser; }
want glmark2 && { say "$TARGET: glmark2 x$RUNS"; in_vm glmark2 "$RUNS" </dev/null | each glmark2; }
say "$TARGET: done, $OUT"
