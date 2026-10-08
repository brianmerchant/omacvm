#!/bin/bash
# mac-ime, guest side, without a VM: the port protocol (protocol-test.cpp,
# with the sanitizers where the compiler has them) and the VM step
# (install-test.sh: install.sh with pacman, makepkg and systemd replaced).
#   src/ime/tests/run.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ime.XXXXXX")
trap 'rm -rf "$work"' EXIT
cxx=${CXX:-c++}
san=(-fsanitize=address,undefined -fno-omit-frame-pointer)
"$cxx" -std=c++17 "${san[@]}" -x c++ /dev/null -c -o "$work/probe.o" 2>/dev/null || san=()
"$cxx" -std=c++17 -O1 -g -Wall -Wextra -Werror "${san[@]}" \
  "$here/protocol-test.cpp" "$here/../guest/addon/protocol.cpp" -o "$work/protocol-test"
"$work/protocol-test"
"$here/install-test.sh"
