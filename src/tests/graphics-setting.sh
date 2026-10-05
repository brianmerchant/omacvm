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
export OMACVM_TEST_VENUS_SWITCH=0
while IFS='|' read -r left want_s; do
  read -r c macos kk ready forced mac vm _ want_v want_m <<<"$left"; want_s=${want_s# }
  d=$T/vm; rm -rf "$d"; mkdir -p "$d"
  echo "$c" > "$d/graphics"
  (( ready )) && : > "$d/venus-ready"
  (( forced )) && : > "$d/vulkan"
  got_v=$(OMACVM_TEST_MACOS_MAJOR=$macos OMACVM_TEST_KOSMICKRISP=$kk graphics_next_start "$d")
  got_s=$(OMACVM_TEST_MACOS_MAJOR=$macos OMACVM_TEST_KOSMICKRISP=$kk graphics_summary "$d")
  got_m=$(graphics_hostmem_gb "$mac" "$vm")
  n=$((n + 1))
  if [[ $got_v != "$want_v" || $got_m != "$want_m" || $got_s != "$want_s" ]]; then
    diff=$((diff + 1)); (( diff <= 5 )) && echo "  differs: $c macOS $macos kk $kk ready $ready forced $forced $mac/$vm GB: app $want_v $want_m '$want_s', omacvm $got_v $got_m '$got_s'"
  fi
done < "$T/swift.txt"
(( diff == 0 )) && ok "app and omacvm agree on $n cases" || bad "app and omacvm differ in $diff of $n cases"

line() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f1 | awk '{ print $(NF-1) }'; }
mem() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f1 | awk '{ print $NF }'; }
summ() { grep "^$1 -> " "$T/swift.txt" | cut -d'|' -f2- | sed 's/^ //'; }
# The rules (choice macOS kk ready forced macGB vmGB).
expect "OpenGL: no Vulkan"                          opengl "$(line 'opengl 27 1 1 0 16 8')"
expect "Vulkan with the driver: Vulkan"             vulkan "$(line 'vulkan 15 0 1 0 16 8')"
expect "Vulkan without the driver: OpenGL"          opengl "$(line 'vulkan 15 0 0 0 16 8')"
expect "  ... and says so" "Vulkan (driver not built yet: runs on OpenGL until the next apply)" "$(summ 'vulkan 27 1 0 0 16 8')"
expect "Automatic, macOS 27 + KosmicKrisp + driver: OpenGL (3.0.0)" opengl "$(line 'auto 27 1 1 0 16 8')"
expect "Automatic waits for the VM's driver"        opengl "$(line 'auto 27 1 0 0 16 8')"
expect "Automatic, macOS 26 without KosmicKrisp"    opengl "$(line 'auto 26 0 1 0 16 8')"
expect "Automatic, macOS 15 (MoltenVK)"             opengl "$(line 'auto 15 1 1 0 16 8')"
expect "vulkan feature keeps Vulkan under OpenGL"   vulkan "$(line 'opengl 15 0 0 1 16 8')"
# The host memory window: what the Mac has beyond the VM and macOS's reserve.
expect "8 GB Mac, 4 GB VM: 1 GB"    1  "$(mem 'auto 15 0 0 0 8 4')"
expect "16 GB Mac, 8 GB VM: 4 GB"   4  "$(mem 'auto 15 0 0 0 16 8')"
expect "36 GB Mac, 16 GB VM: 8 GB"  8  "$(mem 'auto 15 0 0 0 36 16')"
expect "128 GB Mac, 16 GB VM: 32 GB (most)" 32 "$(mem 'auto 15 0 0 0 128 16')"
expect "128 GB Mac, 48 GB VM: 64 -> 32 GB"  32 "$(mem 'auto 15 0 0 0 128 48')"

# The hidden venus switch of 2.9 (moved once): a VM without its own choice
# gets Vulkan, one set to OpenGL keeps it; omacvm reads the switch the same way
# until the app has moved it.
m=$T/m; mkdir -p "$m/a" "$m/b" "$m/c"; echo opengl > "$m/b/graphics"; echo auto > "$m/c/graphics"
"$T/graphics" migrate "$m/a" "$m/b" "$m/c" > "$T/migrate.txt"
expect "switch: VM without a choice -> vulkan (app)" vulkan "$(cat "$m/a/graphics")"
expect "switch: VM on OpenGL keeps it (app)" opengl "$(cat "$m/b/graphics")"
expect "switch: VM on Automatic -> vulkan (app)" vulkan "$(cat "$m/c/graphics")"
expect "switch: logged per VM" 2 "$(grep -c 'hidden venus switch was on' "$T/migrate.txt")"
rm -f "$m/a/graphics" "$m/c/graphics"
expect "switch on: no file -> vulkan (omacvm)" vulkan "$(OMACVM_TEST_VENUS_SWITCH=1 graphics_choice "$m/a")"
expect "switch on: OpenGL stays (omacvm)" opengl "$(OMACVM_TEST_VENUS_SWITCH=1 graphics_choice "$m/b")"
expect "switch off: no file -> auto (omacvm)" auto "$(OMACVM_TEST_VENUS_SWITCH=0 graphics_choice "$m/a")"
grep -q 'Settings.migrateVenusSwitch()' "$R/app/app/Sources/OmacVM/main.swift" && ! grep -q 'Settings.venus' "$R/app/app/Sources/OmacVM/Runner.swift" &&
  ok "the app moves the switch at launch and no longer reads it at start" || bad "the app still reads the hidden venus switch"

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
s_auto=$(sed -n 's/.*static let autoVulkan = \([a-z]*\).*/\1/p' "$R/app/app/Sources/OmacVM/Graphics.swift")
expect "Automatic gives Vulkan at all: same" "$([[ $s_auto == true ]] && echo 1 || echo 0)" "$GRAPHICS_AUTO_VULKAN"
expect "3.0.0: Automatic is OpenGL on every Mac" 0 "$GRAPHICS_AUTO_VULKAN"
expect "waiting-for-driver text: same" "$("$T/graphics" waiting)" "$GRAPHICS_WAITING_FOR_DRIVER"
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
cli() { HOME=$H OMACVM_TEST_MACOS_MAJOR=${MAJ:-15} OMACVM_TEST_KOSMICKRISP=${KK:-0} OMACVM_TEST_VENUS_SWITCH=0 \
          "$R/src/cmd/graphics.sh" --vm "Test VM" "$@"; }
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[1]))' "$1"; }
expect "omacvm graphics: a VM that never started" auto "$(cli --json | j graphics)"
expect "omacvm graphics: set vulkan" True "$(cli vulkan --json | j changed)"
expect "omacvm graphics: written" vulkan "$(cat "$H/OmacVM/Test VM/graphics")"
expect "omacvm graphics: vulkan without the driver: OpenGL next start" opengl "$(cli --json | j next_start)"
expect "omacvm graphics: ... waiting for the driver" True "$(cli --json | j waiting_for_driver)"
expect "omacvm graphics: ... and says so" "Vulkan (driver not built yet: runs on OpenGL until the next apply)" "$(cli --json | j summary)"
: > "$H/OmacVM/Test VM/venus-ready"
expect "omacvm graphics: vulkan with the driver" vulkan "$(cli --json | j next_start)"
expect "omacvm graphics: auto on macOS 27 + KK with the driver: OpenGL (3.0.0)" opengl "$(cli auto --json >/dev/null; MAJ=27 KK=1 cli --json | j next_start)"
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
