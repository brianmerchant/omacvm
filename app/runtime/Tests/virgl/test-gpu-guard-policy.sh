#!/bin/bash
# The desktop reserve's rules (virgl-gpu-guard-desktop-reserve.patch): the
# patch's new src/virgl_gpu_guard.h goes into an empty folder and
# test-gpu-guard-policy.c runs against it. No GL, no renderer. CI runs it; the
# runtime build runs the renderer itself (test-resource-budget.c, mode reserve).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
patch_file="$here/../../patches/virgl-gpu-guard-desktop-reserve.patch"
work=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-gpu-guard.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The header is a new file: every line of its hunk starts with "+".
awk '/^\+\+\+ b\/src\/virgl_gpu_guard\.h/ { on = 1; next }
     on && /^(--- |diff )/ { exit }
     on && /^@@/ { next }
     on { print substr($0, 2) }' "$patch_file" > "$work/virgl_gpu_guard.h"
[[ -s $work/virgl_gpu_guard.h ]] || { echo "FAIL: no src/virgl_gpu_guard.h in $patch_file"; exit 1; }
cc -std=c11 -Wall -Wextra -Werror -I"$work" "$here/test-gpu-guard-policy.c" -o "$work/test-gpu-guard-policy"
"$work/test-gpu-guard-policy"
