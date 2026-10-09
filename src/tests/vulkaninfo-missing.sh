#!/bin/bash
# The guest check's "Vulkan (Venus)" line without vulkaninfo (no vulkan-tools,
# a fresh prebuilt VM): "not checked", never "no Venus device" (#332); with it
# as before. The check's own lines run with stand-ins for the driver's status
# and vulkaninfo. Also: apply's app step installs vulkan-tools with the driver.
#   src/tests/vulkaninfo-missing.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
fails=0
pass() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The check's Vulkan (Venus) block, its status script pointed at a stand-in.
sed -n '/^  # Vulkan (Venus), with the app.s Vulkan switch on/,/^  FEATURE=""$/p' src/guest/check.sh |
  sed "s|/usr/local/share/omacvm/app/guest/venus/vulkan-virtio.sh|$T/status|; s|/etc/vulkan/icd.d/omacvm_venus_icd.json|$T/none.json|" > "$T/block"
grep -q 'vulkaninfo' "$T/block" || { echo "FAIL the Vulkan (Venus) block was not found in src/guest/check.sh"; exit 1; }
printf '#!/bin/bash\necho "ok vulkan-virtio 1:26.2.4.omacvm2-1 sizes GPU memory to 16384-byte pages"\n' > "$T/status"
mkdir "$T/bin"
printf '#!/bin/bash\nprintf "GPU0:\\n\\tdeviceName         = Virtio-GPU Venus (Apple M4) (MESA_KOSMICKRISP)\\n"\n' > "$T/bin/vulkaninfo"
chmod +x "$T/status" "$T/bin/vulkaninfo"
row() {   # PATH: the line the block says
  env -i PATH="$1" /bin/bash -c 'ok() { echo "ok|$1|$2"; }; bad() { echo "fail|$1|$2"; }; skip() { echo "skip|$1|$2"; }
    source "$0"' "$T/block"
}
r=$(row "/usr/bin:/bin")
[[ $r == "skip|Vulkan (Venus)|not checked: vulkaninfo missing (vulkan-tools"* ]] && pass "no vulkaninfo: not checked (skip), not 'no Venus device'" ||
  fail "no vulkaninfo: $r"
r=$(row "$T/bin:/usr/bin:/bin")
[[ $r == "ok|Vulkan (Venus)|Virtio-GPU Venus"* ]] && pass "vulkaninfo finds Venus: ok" || fail "with vulkaninfo: $r"
printf '#!/bin/bash\necho "GPU0: deviceName = llvmpipe"\n' > "$T/bin/vulkaninfo"
r=$(row "$T/bin:/usr/bin:/bin")
[[ $r == "fail|Vulkan (Venus)|"*"vulkaninfo finds no Venus device" ]] && pass "vulkaninfo without a Venus device: still a failure" || fail "no Venus: $r"
grep -qF 'pkg-add vulkan-tools' src/app/guest/install.sh && pass "apply's app step installs vulkan-tools with the Venus driver" ||
  fail "src/app/guest/install.sh does not install vulkan-tools"
(( fails == 0 )) && echo "vulkaninfo missing: all ok" || { echo "vulkaninfo missing: $fails failed"; exit 1; }
