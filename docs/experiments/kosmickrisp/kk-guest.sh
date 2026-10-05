#!/bin/bash
# kk-guest.sh TEST (root, in the VM): the kosmickrisp track's guest tests, as the session user.
#   info | vkmark [args] | vkcube | glmark2-zink | glmark2-virgl | glinfo-zink | clinfo | clpeak | gb-opencl
U=$(loginctl list-sessions --no-legend | awk '$4=="seat0"{print $3; exit}'); U=${U:-gilles}
SIG=$(ls -t /run/user/1000/hypr 2>/dev/null | head -1)
SESS=(runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 HYPRLAND_INSTANCE_SIGNATURE=$SIG)
M=/opt/mesa-kk
VK=(VK_DRIVER_FILES=$M/share/vulkan/icd.d/virtio_icd.aarch64.json)
ZINK=(LD_LIBRARY_PATH=$M/lib __EGL_VENDOR_LIBRARY_FILENAMES=$M/share/glvnd/egl_vendor.d/50_mesa.json
      LIBGL_DRIVERS_PATH=$M/lib/dri GBM_BACKENDS_PATH=$M/lib/gbm MESA_LOADER_DRIVER_OVERRIDE=zink "${VK[@]}")
CL=(LD_LIBRARY_PATH=$M/lib OCL_ICD_VENDORS=$M/etc/OpenCL/vendors RUSTICL_ENABLE=zink "${VK[@]}")
t=$1; shift
case $t in
  info)    "${SESS[@]}" "${VK[@]}" vulkaninfo --summary 2>&1
           "${SESS[@]}" "${VK[@]}" vulkaninfo 2>/dev/null | grep -E "nullDescriptor|robustBufferAccess2|geometryShader|logicOp|shaderFloat64|tessellationShader|driverInfo|apiVersion" | sort -u ;;
  vkmark)  "${SESS[@]}" "${VK[@]}" vkmark "$@" 2>&1 ;;
  vkcube)  s=$(date +%s.%N); "${SESS[@]}" "${VK[@]}" timeout 60 vkcube --wsi wayland --c ${1:-300} 2>&1
           echo "exit $? frames ${1:-300} in $(python3 -c "print(round($(date +%s.%N) - $s, 2))") s" ;;
  glinfo-zink)  "${SESS[@]}" "${ZINK[@]}" eglinfo -B 2>&1 | grep -E "renderer|version|Wayland|GBM|device" | head -30 ;;
  glmark2-zink) "${SESS[@]}" "${ZINK[@]}" glmark2-es2-wayland "$@" 2>&1 ;;
  glmark2-zink-gl) "${SESS[@]}" "${ZINK[@]}" glmark2-wayland "$@" 2>&1 ;;
  glmark2-virgl) "${SESS[@]}" glmark2-es2-wayland "$@" 2>&1 ;;
  clinfo)  env "${CL[@]}" clinfo "$@" 2>&1 ;;
  clpeak)  env "${CL[@]}" clpeak "$@" 2>&1 ;;
  gb-list) env "${CL[@]}" /root/gb/Geekbench-7.0.0-LinuxARMPreview/geekbench7 --gpu-list 2>&1 ;;
  gb-opencl) env "${CL[@]}" /root/gb/Geekbench-7.0.0-LinuxARMPreview/geekbench7 --gpu OpenCL "$@" 2>&1 ;;
  *) echo "unknown test $t"; exit 2 ;;
esac
