#!/bin/bash
# The mac-ime Fcitx5 module compiles and links against an installed Fcitx5
# (the same command as its PKGBUILD's build()), and exports the factory
# Fcitx5 looks for. CI runs it on Linux with Ubuntu's Fcitx5; in the VM the
# package build does the same against Arch Linux ARM's.
#   src/ime/tests/build-addon.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
addon=$here/../guest/addon
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-ime-addon.XXXXXX")
trap 'rm -rf "$work"' EXIT
# shellcheck disable=SC2046 # pkg-config's flags, one per word
g++ -std=c++20 -O2 -fPIC -shared -fvisibility=hidden -Wall -Wextra -Werror \
  $(pkg-config --cflags Fcitx5Core Fcitx5Utils) \
  "$addon/omacvmime.cpp" "$addon/protocol.cpp" -o "$work/libomacvmime.so" \
  -Wl,--as-needed -Wl,--no-undefined $(pkg-config --libs Fcitx5Core Fcitx5Utils)
nm -D --defined-only "$work/libomacvmime.so" | grep -q ' fcitx_addon_factory_instance' &&
  echo "ok   libomacvmime.so builds and exports its factory (Fcitx5 $(pkg-config --modversion Fcitx5Core))" ||
  { echo "FAIL libomacvmime.so exports no fcitx_addon_factory_instance"; exit 1; }
grep -qx 'Library=libomacvmime' "$addon/omacvmime.conf" && echo "ok   its addon file names the library" ||
  { echo "FAIL omacvmime.conf does not name libomacvmime"; exit 1; }
