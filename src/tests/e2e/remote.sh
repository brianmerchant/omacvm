#!/bin/bash
# The e2e gate for a release commit, run on the test Mac from the release Mac
# (src/release/release.sh step e2e): fetches COMMIT into a checkout there,
# builds the test identity from it, runs cc-switches.sh and brings back
# result.json and summary.tsv.
#   src/tests/e2e/remote.sh COMMIT LOCAL_OUT_DIR
# Settings (environment):
#   OMACVM_E2E_SSH        how to reach the test Mac, e.g. "ssh -i ~/.ssh/key user@host" (required)
#   OMACVM_E2E_DIR        the checkout there (default: omacvm-e2e-src in its home); kept, so
#                         QEMU's runtime is built again only when its inputs change
#   OMACVM_E2E_BUILD_ENV  extra environment for build-app.sh there (e.g. OMACVM_KOSMICKRISP_FROM=...)
#   OMACVM_E2E_ARGS       arguments for cc-switches.sh (required: at least --vm NAME or
#                         --clone-from KEPT --vm NAME; --previous latest for the update path)
#   OMACVM_SIGN_ID        the Developer ID there (the same as here)
#   OMACVM_E2E_APP        a test identity build of COMMIT made here (app/scripts/build-app.sh
#                         --test-identity in a checkout of it): copied over and used instead of a
#                         build there (a test Mac whose SSH session cannot reach the Developer ID)
set -euo pipefail
M=${1:?usage: remote.sh COMMIT LOCAL_OUT_DIR}; LOUT=${2:?usage: remote.sh COMMIT LOCAL_OUT_DIR}
SSH=${OMACVM_E2E_SSH:?OMACVM_E2E_SSH: how to reach the test Mac (ssh ... user@host)}
ARGS=${OMACVM_E2E_ARGS:?OMACVM_E2E_ARGS: cc-switches.sh arguments (--vm NAME ...)}
D=${OMACVM_E2E_DIR:-omacvm-e2e-src}
SIGN=${OMACVM_SIGN_ID:?OMACVM_SIGN_ID}
ROUT=omacvm-e2e/gate-${M:0:12}-$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOUT"
q() { printf '%q' "$1"; }
# The ssh command as written (eval: a ~ in it is the home folder here), then one remote command line.
rsh() { eval "$SSH" "$(q "$1")"; }
APPARG="app/dist/OmacVM Test.app"; BUILD=1
if [[ -n ${OMACVM_E2E_APP:-} ]]; then
  [[ $(/usr/libexec/PlistBuddy -c 'Print :OmacVMCommit' "$OMACVM_E2E_APP/Contents/Info.plist" 2>/dev/null) == "$M" ]] ||
    { echo "remote.sh: $OMACVM_E2E_APP is not a build of $M" >&2; exit 1; }
  z=$(mktemp -d)/app.zip
  ditto -c -k --keepParent "$OMACVM_E2E_APP" "$z"
  echo "==> test Mac: the test app built here ($(du -h "$z" | cut -f1))"
  rsh "mkdir -p omacvm-e2e-app && rm -rf omacvm-e2e-app/x && cat > omacvm-e2e-app/app.zip" < "$z"
  rsh "cd omacvm-e2e-app && mkdir x && ditto -x -k app.zip x && codesign --verify --deep --strict 'x/OmacVM Test.app'"
  rm -rf "$(dirname "$z")"
  APPARG="\$HOME/omacvm-e2e-app/x/OmacVM Test.app"; BUILD=0
fi
echo "==> test Mac: checkout $M$( (( BUILD )) && echo ", test identity build")"
rsh "set -e; cd; [ -d $(q "$D")/.git ] || git clone -q https://github.com/gillesgoetsch/OmacVM $(q "$D"); cd $(q "$D")
  git fetch -q origin; git checkout -q --detach $(q "$M"); git clean -qfdx -e app/runtime/.build
  export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH OMACVM_SIGN_ID=$(q "$SIGN") ${OMACVM_E2E_BUILD_ENV:-}
  if [ $BUILD = 1 ]; then app/scripts/build-app.sh --test-identity > build-e2e.log 2>&1 || { tail -20 build-e2e.log; exit 1; }
    [ \"\$(/usr/libexec/PlistBuddy -c 'Print :OmacVMCommit' 'app/dist/OmacVM Test.app/Contents/Info.plist')\" = $(q "$M") ]; fi"
echo "==> test Mac: cc-switches.sh $ARGS"
rc=0
rsh "cd $(q "$D") && OMACVM_SIGN_ID=$(q "$SIGN") src/tests/e2e/cc-switches.sh --app \"$APPARG\" --out \"\$HOME/$ROUT\" $ARGS" || rc=$?
for f in result.json summary.tsv; do
  rsh "cat \"\$HOME/$ROUT/$f\"" > "$LOUT/$f" || { echo "remote.sh: no $f from the test Mac" >&2; exit 1; }
done
echo "==> result: $(/usr/bin/python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); print("pass" if o["pass"] else "NOT passed", o["counts"])' "$LOUT/result.json") (cc-switches exit $rc)"
exit "$rc"
