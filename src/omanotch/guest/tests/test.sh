#!/bin/bash
# Offline tests of Omanotch's VM side (no Wayland, no Hyprland needed).
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -std=c11 -Wall -Wextra -Werror -I../notchcast -o "$out/notch-place-test" notch-place-test.c
"$out/notch-place-test"
