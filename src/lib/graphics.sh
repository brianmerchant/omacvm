# OmacVM.app's Graphics setting on the Mac side (omacvm apply, omacvm graphics,
# omacvm check): the same rules as app/app/Sources/OmacVM/Graphics.swift,
# which the app uses at each VM start. src/tests/graphics-setting.sh checks
# that both give the same answers.
# A VM folder's `graphics` file: opengl, vulkan or auto (none = auto).
# Venus (Vulkan) at a start: vulkan or auto-picks-Vulkan, once the VM has its
# Venus driver (`venus-ready`, written by omacvm apply; before that OpenGL:
# GRAPHICS_WAITING_FOR_DRIVER); or the vulkan feature's `vulkan` file (always).

GRAPHICS_AUTO_VULKAN=0               # Graphics.autoVulkan (3.0.0: Automatic = OpenGL on every Mac)
GRAPHICS_AUTO_VULKAN_FROM_MACOS=26   # Graphics.autoVulkanFromMacOS
GRAPHICS_AUTO_VULKAN_ON_MOLTENVK=0   # Graphics.autoVulkanOnMoltenVK
GRAPHICS_WAITING_FOR_DRIVER="driver not built yet: runs on OpenGL until the next apply"   # Graphics.waitingForDriver

graphics_choice() {   # DIR -> opengl|vulkan|auto
  local c
  c=$(tr -d "[:space:]" 2>/dev/null < "$1/graphics") || c=""
  case $c in opengl|vulkan) echo "$c"; return ;; esac
  # Up to 2.9 the app's hidden `venus` switch put Vulkan in every VM; the
  # 3.0.0 app moves it into this file at its first launch and removes it
  # (Graphics.migrateVenusSwitch). Until then omacvm reads it the same way.
  if [[ -n ${OMACVM_TEST_VENUS_SWITCH+x} ]]; then [[ $OMACVM_TEST_VENUS_SWITCH == 1 ]] && { echo vulkan; return; }
  elif [[ $(defaults read "${APP_ID:-org.omacvm.app}" venus 2>/dev/null) == 1 ]]; then echo vulkan; return; fi
  echo auto
}

graphics_macos_major() { echo "${OMACVM_TEST_MACOS_MAJOR:-$(sw_vers -productVersion | cut -d. -f1)}"; }

# The OmacVM.app whose runtime has KosmicKrisp (Metal 4, macOS 26+).
graphics_kosmickrisp() {
  [[ -n ${OMACVM_TEST_KOSMICKRISP:-} ]] && { [[ $OMACVM_TEST_KOSMICKRISP == 1 ]]; return; }
  # apply-vm.sh: the app that runs it (and its VM).
  [[ -n ${OMACVM_APP_RUNTIME:-} ]] && { [[ -e $OMACVM_APP_RUNTIME/lib/libvulkan_kosmickrisp.dylib ]]; return; }
  local a
  a=$(app_bundle 2>/dev/null) || return 1
  [[ -e $a/Contents/Resources/runtime/lib/libvulkan_kosmickrisp.dylib ]]
}

graphics_auto_vulkan() {   # MACOS_MAJOR KK(0|1): Automatic gives Vulkan on this Mac
  (( GRAPHICS_AUTO_VULKAN && (($1 >= GRAPHICS_AUTO_VULKAN_FROM_MACOS && $2) || GRAPHICS_AUTO_VULKAN_ON_MOLTENVK) ))
}

graphics_forced() {   # DIR: the vulkan feature (OmacVM's Mesa) keeps Venus on
  [[ -e $1/vulkan ]]
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

# DIR: Vulkan wanted, but the VM has no Venus driver for 16 KiB pages yet
# (OpenGL until then: with the old driver every Vulkan app fails).
graphics_waiting_for_driver() {
  [[ $(graphics_wants "$1") == vulkan && ! -e $1/venus-ready ]] && ! graphics_forced "$1"
}

# DIR -> vulkan|opengl at the VM's next start (with the driver condition).
graphics_next_start() {
  if graphics_waiting_for_driver "$1"; then echo opengl; else graphics_wants "$1"; fi
}

# DIR -> the next start in words (GraphicsPlan.summary).
graphics_summary() {
  if [[ $(graphics_next_start "$1") == vulkan ]]; then echo "OpenGL and Vulkan"
  elif [[ $(graphics_choice "$1") == vulkan ]] && graphics_waiting_for_driver "$1"; then echo "Vulkan ($GRAPHICS_WAITING_FOR_DRIVER)"
  else echo OpenGL; fi
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
