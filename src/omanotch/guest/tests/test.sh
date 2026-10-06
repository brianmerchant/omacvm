#!/bin/bash
# Offline tests of Omanotch's guest side (no VM, no screen).
set -euo pipefail
cd "$(dirname "$0")"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
cc -std=c11 -Wall -Wextra -o "$out/test_notchrule" test_notchrule.c -lm
"$out/test_notchrule"
python3 test_bar_patch.py
