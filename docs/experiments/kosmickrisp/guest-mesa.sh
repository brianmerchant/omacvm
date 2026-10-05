#!/bin/bash
# guest-mesa.sh (root, in the VM): Mesa main (same commit as the host's KosmicKrisp) with
# venus + zink + rusticl into /opt/mesa-kk. Tools for the tests: clinfo, ocl-icd, clpeak.
set -euxo pipefail
C=e5f0687867f5c5e88619175d9b0442f8560e8d53
pacman -S --needed --noconfirm base-devel meson ninja cmake git python-mako python-yaml python-packaging python-ply \
  glslang wayland wayland-protocols libdrm libx11 libxext libxfixes libxshmfence libxxf86vm libxrandr libxcb \
  xcb-util-keysyms llvm clang libclc spirv-llvm-translator spirv-tools spirv-headers rust rust-bindgen cbindgen \
  libelf zstd expat lm_sensors libglvnd ocl-icd opencl-headers clinfo vulkan-icd-loader vulkan-headers \
  vulkan-tools vkmark glmark2 mesa-utils
mkdir -p /opt/src && cd /opt/src
if [ ! -d mesa-$C ]; then
  curl -fsSL https://gitlab.freedesktop.org/mesa/mesa/-/archive/$C/mesa-$C.tar.gz | tar -xz
fi
cd mesa-$C
rm -rf build
meson setup build --prefix=/opt/mesa-kk --libdir=lib --buildtype=release -Db_ndebug=true \
  -Dplatforms=wayland,x11 -Dvulkan-drivers=virtio -Dgallium-drivers=zink,virgl \
  -Dgallium-rusticl=true -Dllvm=enabled -Dshared-llvm=enabled -Dglx=dri -Degl=enabled -Dgbm=enabled \
  -Dglvnd=enabled -Dvideo-codecs= -Dtools= -Dbuild-tests=false
ninja -C build
ninja -C build install
# clpeak (no Arch package)
cd /opt/src
[ -d clpeak ] || git clone --depth 1 --recurse-submodules https://github.com/krrishnarraj/clpeak.git
cmake -S clpeak -B clpeak/build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build clpeak/build -j6 >/dev/null
install -m755 clpeak/build/clpeak /usr/local/bin/clpeak
echo GUEST-MESA-OK
