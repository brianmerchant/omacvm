#!/bin/bash
# OmacVM.app's Graphics setting: the app (app/app/Sources/OmacVM/Graphics.swift)
# and the Mac side of omacvm (src/lib/graphics.sh) decide the same for every
# case (macOS version, KosmicKrisp in the app, the VM's Venus driver, the
# vulkan feature, Mac and VM memory), plus the rules themselves. No VM.
set -u
R=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
expect() { [[ $2 == "$3" ]] && ok "$1" || bad "$1: got '$3', want '$2'"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

swiftc -O -o "$T/graphics" "$R/app/app/Sources/OmacVM/Graphics.swift" "$R/src/tests/graphics-setting/main.swift" ||
  { echo "FAIL Graphics.swift does not build on its own"; exit 1; }
"$T/graphics" > "$T/swift.txt"

source "$R/src/lib/graphics.sh"
app_bundle() { return 1; }
n=0; diff=0
while read -r c macos kk ready forced mac vm _ want_v want_m; do
  d=$T/vm; rm -rf "$d"; mkdir -p "$d"
  echo "$c" > "$d/graphics"
  (( ready )) && : > "$d/venus-ready"
  got_v=$(OMACVM_TEST_MACOS_MAJOR=$macos OMACVM_TEST_KOSMICKRISP=$kk OMACVM_TEST_VENUS_DEFAULT=$forced graphics_next_start "$d")
  got_m=$(graphics_hostmem_gb "$mac" "$vm")
  n=$((n + 1))
  if [[ $got_v != "$want_v" || $got_m != "$want_m" ]]; then
    diff=$((diff + 1)); (( diff <= 5 )) && echo "  differs: $c macOS $macos kk $kk ready $ready forced $forced $mac/$vm GB: app $want_v $want_m, omacvm $got_v $got_m"
  fi
done < "$T/swift.txt"
(( diff == 0 )) && ok "app and omacvm agree on $n cases" || bad "app and omacvm differ in $diff of $n cases"

line() { grep "^$1 -> " "$T/swift.txt" | awk '{ print $(NF-1) }'; }
# The rules (choice macOS kk ready forced macGB vmGB).
expect "OpenGL: no Vulkan"                          opengl "$(line 'opengl 27 1 1 0 16 8')"
expect "Vulkan: Vulkan, also without the driver"    vulkan "$(line 'vulkan 15 0 0 0 16 8')"
expect "Automatic, macOS 27 + KosmicKrisp + driver" vulkan "$(line 'auto 27 1 1 0 16 8')"
expect "Automatic waits for the VM's driver"        opengl "$(line 'auto 27 1 0 0 16 8')"
expect "Automatic, macOS 26 without KosmicKrisp"    opengl "$(line 'auto 26 0 1 0 16 8')"
expect "Automatic, macOS 15 (MoltenVK)"             opengl "$(line 'auto 15 1 1 0 16 8')"
expect "vulkan feature keeps Vulkan under OpenGL"   vulkan "$(line 'opengl 15 0 0 1 16 8')"
# The host memory window: what the Mac has beyond the VM and macOS's reserve.
expect "8 GB Mac, 4 GB VM: 1 GB"    1  "$(grep '^auto 15 0 0 0 8 4 ' "$T/swift.txt" | awk '{ print $NF }')"
expect "16 GB Mac, 8 GB VM: 4 GB"   4  "$(grep '^auto 15 0 0 0 16 8 ' "$T/swift.txt" | awk '{ print $NF }')"
expect "36 GB Mac, 16 GB VM: 8 GB"  8  "$(grep '^auto 15 0 0 0 36 16 ' "$T/swift.txt" | awk '{ print $NF }')"
expect "128 GB Mac, 16 GB VM: 32 GB (most)" 32 "$(grep '^auto 15 0 0 0 128 16 ' "$T/swift.txt" | awk '{ print $NF }')"
expect "128 GB Mac, 48 GB VM: 64 -> 32 GB"  32 "$(grep '^auto 15 0 0 0 128 48 ' "$T/swift.txt" | awk '{ print $NF }')"

# The file: missing or unknown means Automatic, in both.
d=$T/f; mkdir -p "$d"
expect "no file: auto (app)"     auto "$("$T/graphics" file "$d")"
expect "no file: auto (omacvm)"  auto "$(graphics_choice "$d")"
printf 'metal\n' > "$d/graphics"
expect "unknown value: auto (app)"    auto "$("$T/graphics" file "$d")"
expect "unknown value: auto (omacvm)" auto "$(graphics_choice "$d")"
printf ' vulkan \n' > "$d/graphics"
expect "spaces around: vulkan (app)"    vulkan "$("$T/graphics" file "$d")"
expect "spaces around: vulkan (omacvm)" vulkan "$(graphics_choice "$d")"

# The constants are the same in both.
s_from=$(sed -n 's/.*static let autoVulkanFromMacOS = \([0-9]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
s_mvk=$(sed -n 's/.*static let autoVulkanOnMoltenVK = \([a-z]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
expect "Automatic from macOS: same" "$s_from" "$GRAPHICS_AUTO_VULKAN_FROM_MACOS"
expect "Automatic on MoltenVK: same" "$([[ $s_mvk == true ]] && echo 1 || echo 0)" "$GRAPHICS_AUTO_VULKAN_ON_MOLTENVK"

# omacvm graphics on a stopped VM, in a throwaway HOME and settings domain
# (no real VM, app or setting).
H=$T/home; mkdir -p "$H/OmacVM/Test VM/logs"
printf "NAME='Test VM'\nSSH_PORT=52999\n" > "$H/OmacVM/Test VM/vm.env"
export OMACVM_APP_ID=org.omacvm.test.graphics-setting.$$
trap 'defaults delete "$OMACVM_APP_ID" >/dev/null 2>&1; rm -rf "$T"' EXIT
cli() { HOME=$H OMACVM_TEST_MACOS_MAJOR=${MAJ:-15} OMACVM_TEST_KOSMICKRISP=${KK:-0} OMACVM_TEST_VENUS_DEFAULT=0 \
          "$R/src/cmd/graphics.sh" --vm "Test VM" "$@"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }
expect "omacvm graphics: a VM that never started" auto "$(cli --json | j graphics)"
expect "omacvm graphics: set vulkan" True "$(cli vulkan --json | j changed)"
expect "omacvm graphics: written" vulkan "$(cat "$H/OmacVM/Test VM/graphics")"
expect "omacvm graphics: vulkan next start" vulkan "$(cli --json | j next_start)"
expect "omacvm graphics: auto on macOS 27 + KK, no driver yet" opengl "$(cli auto --json >/dev/null; MAJ=27 KK=1 cli --json | j next_start)"
: > "$H/OmacVM/Test VM/venus-ready"
expect "omacvm graphics: auto with the driver" vulkan "$(MAJ=27 KK=1 cli --json | j next_start)"
echo "OmacVM: graphics: auto -> vulkan (macOS 27, KosmicKrisp), host memory window 4 GB" > "$H/OmacVM/Test VM/logs/qemu.log"
expect "omacvm graphics: the last start" "auto -> vulkan (macOS 27, KosmicKrisp), host memory window 4 GB" "$(MAJ=27 KK=1 cli --json | j this_start)"
cli metal >/dev/null 2>&1; expect "omacvm graphics: unknown value refused" 2 "$?"
cli --vm-type utm >/dev/null 2>&1; expect "omacvm graphics: app VMs only" 2 "$?"

# Wired in: the app uses the plan for QEMU's Venus options; apply passes it to the VM.
grep -q 'g.venus ? ",blob=true,venus=true,hostmem=\\(g.hostmemGB)G"' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  ok "Runner's Venus options come from the plan" || bad "Runner.swift does not use the plan"
grep -q 'GI_ARGS+=" --graphics $GRAPHICS"' "$R/src/cmd/apply.sh" && ok "apply passes --graphics" || bad "apply.sh: no --graphics"
grep -q 'vulkan-virtio.sh --ready' "$R/src/cmd/apply.sh" && ok "apply writes venus-ready from the VM" || bad "apply.sh: no venus-ready"
exit $fail
