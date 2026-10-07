#!/bin/bash
# The release script's offline parts: KosmicKrisp from another Mac
# (app/runtime/import-kosmickrisp.sh) is taken only with a matching stamp and
# a system-only dylib; release.sh and appcast.sh refuse bad arguments.
# No key, no network, nothing outside a temp folder.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
expect() {   # WANT(0|1) NAME CMD...: 0 = must pass, 1 = must be refused
  local want=$1 name=$2; shift 2
  if "$@" > "$T/out" 2>&1; then [[ $want == 0 ]] && ok "$name" || { bad "$name (passed)"; cat "$T/out"; }
  else [[ $want == 1 ]] && ok "$name" || { bad "$name (refused)"; cat "$T/out"; }; fi
}

# A copy of the runtime folder's two scripts: the import writes next to them.
rt=$T/runtime; mkdir -p "$rt"
cp "$R/app/runtime/import-kosmickrisp.sh" "$R/app/runtime/build-kosmickrisp.sh" "$rt/"
commit=$(sed -n 's/^mesa_commit=//p' "$rt/build-kosmickrisp.sh")
script=$(shasum -a 256 "$rt/build-kosmickrisp.sh" | cut -d' ' -f1)
kk() {   # DIR: a fake KosmicKrisp build (a tiny arm64 dylib on the system only)
  mkdir -p "$1"
  echo 'int vk_icdGetInstanceProcAddr(void) { return 0; }' > "$T/kk.c"
  cc -arch arm64 -dynamiclib -install_name @rpath/libvulkan_kosmickrisp.dylib -o "$1/libvulkan_kosmickrisp.dylib" "$T/kk.c" ${2:-}
  printf '{\n    "ICD": {\n        "api_version": "1.4.363",\n        "library_path": "../../../lib/libvulkan_kosmickrisp.dylib"\n    },\n    "file_format_version": "1.0.1"\n}\n' > "$1/kosmickrisp_mesa_icd.json"
  echo "Mesa licences" > "$1/LICENSE.mesa-kosmickrisp.txt"
  echo "$commit $script llvm-23.1.2 spirv-llvm-translator-23.1.0.0" > "$1/stamp"
}
if command -v cc >/dev/null; then
  kk "$T/good"
  expect 0 "import: a matching build gives its stamp" "$rt/import-kosmickrisp.sh" "$T/good" --stamp
  [[ $("$rt/import-kosmickrisp.sh" "$T/good" --stamp) == "$(cat "$T/good/stamp")" ]] && ok "import: the stamp is the build's" || bad "import: stamp"
  expect 0 "import: copies the build" "$rt/import-kosmickrisp.sh" "$T/good"
  cmp -s "$T/good/libvulkan_kosmickrisp.dylib" "$rt/.build/kosmickrisp/libvulkan_kosmickrisp.dylib" && ok "import: dylib in .build/kosmickrisp" || bad "import: dylib not copied"
  cp -R "$T/good" "$T/mesa"; sed -i '' "s/^$commit/0000000000000000000000000000000000000000/" "$T/mesa/stamp"
  expect 1 "import: another Mesa commit is refused" "$rt/import-kosmickrisp.sh" "$T/mesa" --stamp
  cp -R "$T/good" "$T/script"; sed -i '' "s/ $script / $(printf '%064d' 0) /" "$T/script/stamp"
  expect 1 "import: another build script is refused" "$rt/import-kosmickrisp.sh" "$T/script" --stamp
  cp -R "$T/good" "$T/noicd"; rm "$T/noicd/kosmickrisp_mesa_icd.json"
  expect 1 "import: a build without its ICD file is refused" "$rt/import-kosmickrisp.sh" "$T/noicd" --stamp
  cp -R "$T/good" "$T/nolic"; : > "$T/nolic/LICENSE.mesa-kosmickrisp.txt"
  expect 1 "import: an empty licence notice is refused" "$rt/import-kosmickrisp.sh" "$T/nolic" --stamp
  # A dylib that links a library outside the system.
  echo 'int other(void) { return 1; }' > "$T/o.c"
  cc -arch arm64 -dynamiclib -install_name "$T/libother.dylib" -o "$T/libother.dylib" "$T/o.c"
  kk "$T/linked" "-L$T -lother"
  expect 1 "import: a dylib linking outside the system is refused" "$rt/import-kosmickrisp.sh" "$T/linked" --stamp
  cp -R "$T/good" "$T/x86"; cc -arch x86_64 -dynamiclib -o "$T/x86/libvulkan_kosmickrisp.dylib" "$T/kk.c" 2>/dev/null &&
    expect 1 "import: an x86_64 dylib is refused" "$rt/import-kosmickrisp.sh" "$T/x86" --stamp
else
  echo "skip the import checks (no cc)"
fi

# release.sh: usage and bad input, before anything is touched.
expect 1 "release.sh: no version prints the usage" "$R/src/release/release.sh"
[[ $("$R/src/release/release.sh" 2>&1) == *--dry-run* ]] && ok "release.sh: usage names --dry-run" || bad "release.sh: usage"
expect 1 "release.sh: not a version" "$R/src/release/release.sh" --dry-run 3.0 check
OMACVM_RELEASE_OUT=$T/out expect 1 "release.sh: an unknown step" "$R/src/release/release.sh" --dry-run 9.9.9 nonsense
expect 1 "release.sh: an unknown option" "$R/src/release/release.sh" --force 9.9.9 check
# The e2e gate (step e2e, checked again by publish): a passing result for M only.
G=$T/gate; mkdir -p "$G/release/e2e"; echo "M=1111111111111111111111111111111111111111" > "$G/release/state"
gate() {   # PASS COMMIT ONLY: a result.json as cc-switches.sh writes it
  printf '{"kind": "omacvm-e2e-cc-switches", "commit": "%s", "version": "9.9.9", "only": "%s", "pass": %s, "counts": {"ok": 40, "FAIL": 0, "BLOCKED": 0, "skip": 2}, "not_ok": [], "seconds": 3600}\n' \
    "$2" "$3" "$1" > "$G/release/e2e/result.json"
}
rel() { OMACVM_RELEASE_OUT=$G "$R/src/release/release.sh" 9.9.9 "$@"; }
expect 1 "e2e: no result is refused" rel e2e
expect 1 "publish: refused while the gate has not passed" rel publish
[[ $(rel publish 2>&1) == *"e2e gate has not passed"* ]] && ok "publish: says why" || bad "publish: no reason given"
gate true 2222222222222222222222222222222222222222 all
expect 1 "e2e: a result for another commit is refused" rel e2e
gate false 1111111111111111111111111111111111111111 all
expect 1 "e2e: a result that did not pass is refused" rel e2e
gate true 1111111111111111111111111111111111111111 ",switches,"
expect 1 "e2e: a run of some steps only is refused" rel e2e
gate true 1111111111111111111111111111111111111111 all
expect 0 "e2e: a passing result for M is taken" rel e2e
[[ $(sed -n 's/^E2E=//p' "$G/release/state" | tail -1) == pass ]] && ok "e2e: the state says pass" || bad "e2e: state"
rm "$G/release/e2e/result.json"; echo "E2E=" >> "$G/release/state"
OMACVM_RELEASE_E2E_OVERRIDE=short expect 1 "e2e: an override without a reason is refused" rel e2e
OMACVM_RELEASE_E2E_OVERRIDE="the test Mac is away; checked by hand on the Air" expect 0 "e2e: an override with a reason" rel e2e
grep -q "checked by hand on the Air" "$G/release/e2e-override.log" && ok "e2e: the override is logged" || bad "e2e: override not logged"
[[ $(sed -n 's/^E2E=//p' "$G/release/state" | tail -1) == override ]] && ok "e2e: the state says override" || bad "e2e: override state"

# appcast.sh ZIP: only an OmacVM-<version>.zip.
touch "$T/Other.zip"
expect 1 "appcast.sh: a zip with another name is refused" "$R/app/scripts/appcast.sh" "$T/Other.zip"

(( fails == 0 )) && echo "all passed" || { echo "$fails failed"; exit 1; }
