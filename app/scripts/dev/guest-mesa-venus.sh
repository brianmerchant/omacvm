#!/bin/bash
# guest-mesa-venus.sh (as root, in an app VM): Mesa's Vulkan driver for virtio-gpu (Venus) only, from
# Mesa 26.2.4, into /opt/mesa-venus. Arch Linux ARM's Mesa 26.2.3 does not round GPU memory to the Mac's
# 16 KiB pages, so Vulkan apps there get no memory; 26.2.4 does. OpenGL stays on the system Mesa.
# Use it per app:  VK_DRIVER_FILES=/opt/mesa-venus/share/vulkan/icd.d/virtio_icd.aarch64.json vkcube
# Needs the app's hidden Venus switch: defaults write org.omacvm.app venus -bool true (then restart the VM).
set -euo pipefail
V=26.2.4
SHA=bce5f7fbebb934373b86c999a064d52fb5065878dc57f287f95346648ec832e9
pacman -S --needed --noconfirm base-devel meson ninja python-mako python-yaml python-packaging libdrm \
  wayland wayland-protocols libxshmfence libxrandr glslang spirv-tools byacc flex bison vulkan-tools vkmark
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
curl -fsSL -o "$T/mesa.tar.xz" "https://archive.mesa3d.org/mesa-$V.tar.xz"
echo "$SHA  $T/mesa.tar.xz" | sha256sum -c -
tar -C "$T" -xJf "$T/mesa.tar.xz"
cd "$T/mesa-$V"
meson setup build --prefix=/opt/mesa-venus -Dbuildtype=release -Dplatforms=wayland -Dgallium-drivers= \
  -Dvulkan-drivers=virtio -Dglx=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled -Dopengl=false \
  -Dllvm=disabled -Dvideo-codecs=
ninja -C build
ninja -C build install
echo "Venus driver in /opt/mesa-venus. Check: VK_DRIVER_FILES=/opt/mesa-venus/share/vulkan/icd.d/virtio_icd.aarch64.json vulkaninfo --summary"
