#!/bin/bash
# Put OmacVM onto a running OmacVM.app VM: `omacvm apply` from the copy of
# OmacVM inside the app (the Mac side its features need, the Bridge token,
# the VM side), with the features in the VM's vm.env.
#   apply-vm.sh VM_DIR [--no-mac] [--reset-host-key]
#     --reset-host-key  the VM was rebuilt or reinstalled: forget its old SSH key
set -euo pipefail
VM_DIR=${1:?usage: apply-vm.sh VM_DIR [--no-mac] [--reset-host-key]}
shift
extra=()
for a in "$@"; do
  case $a in
    --no-mac|--reset-host-key) extra+=("$a") ;;
    *) echo "apply-vm.sh: unknown option $a (--no-mac, --reset-host-key)" >&2; exit 2 ;;
  esac
done
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/vm-common.sh"
vm_load "$VM_DIR"
vssh true < /dev/null 2>/dev/null || die "the VM is not running (or has no SSH yet)"

# A copy of src/ only: the Mac installers build next to their sources, never
# inside the app (or the source tree).
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/omacvm"
cp -R "$OMACVM_SRC" "$tmp/omacvm/src"
# The app's signed Mac helpers (Contents/Helpers): installed instead of
# building them, when made from these sources (src/lib/helpers.sh).
if [[ -d $HERE/../../Helpers ]]; then
  OMACVM_HELPERS=$(cd "$HERE/../../Helpers" && pwd)
  export OMACVM_HELPERS
fi
args=(--vm "$NAME" --vm-type app --ip "127.0.0.1:$SSH_PORT" --user "$VM_USER" --keyboard "$KEYBOARD")
for f in ${FEATURES:-}; do args+=(--feature "$f"); done
# A changed SSH host key: say how to forget it the app's way.
OMA_RESET_HINT="bash '$HERE/apply-vm.sh' '$VM_DIR' --reset-host-key"
export OMA_RESET_HINT
"$tmp/omacvm/src/cmd/apply.sh" "${args[@]}" ${extra[@]+"${extra[@]}"}
