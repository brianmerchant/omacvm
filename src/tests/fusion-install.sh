#!/bin/bash
# Fusion's guest install: the first Hyprland build must run from the source
# tree, whose build-hyprland.sh finds guest/pkg-add next to it. The root-owned
# copy in /usr/local/lib/omacvm/fusion is only for the pacman hook (--hook,
# no pacman calls). 3.0.0-3.0.3 ran the copy, and every new Fusion VM stopped
# at "failed during: VMware Fusion".
set -euo pipefail
cd "$(dirname "$0")/../.."
fails=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
f=src/fusion/guest/install.sh
check "first build runs from the source tree" "grep -qx '\"\$here/build-hyprland.sh\" \"\$U\"' $f"
check "no build from the installed copy without --hook" "! grep -E '^\s*\"\\\$L/build-hyprland.sh\"' $f | grep -vq -- '--hook'"
check "build-hyprland.sh still reaches pkg-add relative to itself" "grep -q '\$here/../../guest/pkg-add' src/fusion/guest/build-hyprland.sh && [[ -x src/guest/pkg-add ]]"
check "the hook calls the installed copy with --hook" "grep -q 'Exec = /usr/local/lib/omacvm/fusion/build-hyprland.sh --hook' $f"
# The hook path never calls pkg-add.
check "--hook skips pkg-add" "grep -q 'if (( ! HOOK )); then \"\$here/../../guest/pkg-add\"' src/fusion/guest/build-hyprland.sh"
# Every guest script that uses "$here/" sets it (build-open-vm-tools.sh did not:
# "here: unbound variable" right after the Hyprland build, 3.0.0-3.0.3).
for g in src/fusion/guest/*.sh; do
  if grep -q '"\$here/' "$g"; then check "$(basename "$g") sets \$here" "grep -qE '^here=' $g"; fi
done
(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
