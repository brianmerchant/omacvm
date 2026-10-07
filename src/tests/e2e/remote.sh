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
echo "==> test Mac: checkout $M, test identity build"
rsh "set -e; cd; [ -d $(q "$D")/.git ] || git clone -q https://github.com/gillesgoetsch/OmacVM $(q "$D"); cd $(q "$D")
  git fetch -q origin; git checkout -q --detach $(q "$M"); git clean -qfdx -e app/runtime/.build
  export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH OMACVM_SIGN_ID=$(q "$SIGN") ${OMACVM_E2E_BUILD_ENV:-}
  app/scripts/build-app.sh --test-identity > build-e2e.log 2>&1 || { tail -20 build-e2e.log; exit 1; }
  [ \"\$(/usr/libexec/PlistBuddy -c 'Print :OmacVMCommit' 'app/dist/OmacVM Test.app/Contents/Info.plist')\" = $(q "$M") ]"
echo "==> test Mac: cc-switches.sh $ARGS"
rc=0
rsh "cd $(q "$D") && OMACVM_SIGN_ID=$(q "$SIGN") src/tests/e2e/cc-switches.sh --app 'app/dist/OmacVM Test.app' --out \"\$HOME/$ROUT\" $ARGS" || rc=$?
for f in result.json summary.tsv; do
  rsh "cat \"\$HOME/$ROUT/$f\"" > "$LOUT/$f" || { echo "remote.sh: no $f from the test Mac" >&2; exit 1; }
done
echo "==> result: $(/usr/bin/python3 -c 'import json,sys; o=json.load(open(sys.argv[1])); print("pass" if o["pass"] else "NOT passed", o["counts"])' "$LOUT/result.json") (cc-switches exit $rc)"
exit "$rc"
