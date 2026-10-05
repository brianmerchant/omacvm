# OmacVM.app's Graphics setting on the Mac side (omacvm apply, omacvm graphics,
# omacvm check): the same rules as app/app/Sources/OmacVM/Graphics.swift,
# which the app uses at each VM start. src/tests/graphics-setting.sh checks
# that both give the same answers.
# A VM folder's `graphics` file: opengl, vulkan or auto (none = auto).
# Venus (Vulkan) at a start: vulkan; or auto where Automatic picks Vulkan and
# the VM has its Venus driver (`venus-ready`, written by omacvm apply); or the
# vulkan feature's `vulkan` file / the hidden `venus` switch (always).

GRAPHICS_AUTO_VULKAN_FROM_MACOS=26   # Graphics.autoVulkanFromMacOS
GRAPHICS_AUTO_VULKAN_ON_MOLTENVK=0   # Graphics.autoVulkanOnMoltenVK

graphics_choice() {   # DIR -> opengl|vulkan|auto
  local c
  c=$(tr -d "[:space:]" 2>/dev/null < "$1/graphics") || c=""
  case $c in opengl|vulkan|auto) echo "$c" ;; *) echo auto ;; esac
}

graphics_macos_major() { echo "${OMACVM_TEST_MACOS_MAJOR:-$(sw_vers -productVersion | cut -d. -f1)}"; }

# The OmacVM.app whose runtime has KosmicKrisp (Metal 4, macOS 26+).
graphics_kosmickrisp() {
  [[ -n ${OMACVM_TEST_KOSMICKRISP:-} ]] && { [[ $OMACVM_TEST_KOSMICKRISP == 1 ]]; return; }
  local a
  a=$(app_bundle 2>/dev/null) || return 1
  [[ -e $a/Contents/Resources/runtime/lib/libvulkan_kosmickrisp.dylib ]]
}

graphics_auto_vulkan() {   # MACOS_MAJOR KK(0|1): Automatic gives Vulkan on this Mac
  (( ($1 >= GRAPHICS_AUTO_VULKAN_FROM_MACOS && $2) || GRAPHICS_AUTO_VULKAN_ON_MOLTENVK ))
}

graphics_forced() {   # DIR: the vulkan feature or the hidden switch keeps Venus on
  [[ -e $1/vulkan ]] && return 0
  [[ -n ${OMACVM_TEST_VENUS_DEFAULT+x} ]] && { [[ $OMACVM_TEST_VENUS_DEFAULT == 1 ]]; return; }
  [[ $(defaults read org.omacvm.app venus 2>/dev/null) == 1 ]]
}

# DIR -> vulkan|opengl: what the VM gets on this Mac once its driver is there
# (omacvm apply builds the driver ahead for vulkan).
graphics_wants() {
  local kk=0
  graphics_kosmickrisp && kk=1
  if graphics_forced "$1"; then echo vulkan; return; fi
  case $(graphics_choice "$1") in
    vulkan) echo vulkan ;;
    opengl) echo opengl ;;
    auto) graphics_auto_vulkan "$(graphics_macos_major)" "$kk" && echo vulkan || echo opengl ;;
  esac
}

# DIR -> vulkan|opengl at the VM's next start (with the driver condition).
graphics_next_start() {
  local w; w=$(graphics_wants "$1")
  if [[ $w == vulkan && $(graphics_choice "$1") == auto && ! -e $1/venus-ready ]] && ! graphics_forced "$1"; then
    echo opengl
  else
    echo "$w"
  fi
}

# Venus's host memory window in GB: Graphics.hostmemGB.
graphics_hostmem_gb() {   # MAC_GB VM_GB
  local reserve=8 free p=1
  (( $1 <= 36 )) && reserve=6
  (( $1 <= 16 )) && reserve=4
  free=$(( $1 - $2 - reserve ))
  (( free < 1 )) && free=1
  (( free > 32 )) && free=32
  while (( p * 2 <= free )); do p=$(( p * 2 )); done
  echo "$p"
}

graphics_title() {   # opengl|vulkan|auto -> its name in the app
  case $1 in opengl) echo OpenGL ;; vulkan) echo Vulkan ;; *) echo Automatic ;; esac
}
