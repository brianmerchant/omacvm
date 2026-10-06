#!/bin/bash
# Build and load visl (the kernel's virtual stateless V4L2 decoder) for the
# running Arch Linux ARM kernel, which ships without it (V4L_TEST_DRIVERS off).
# visl takes H.264/HEVC/VP8/VP9/AV1/MPEG-2 stateless requests and returns
# test-pattern frames: enough to see whether an app drives a V4L2 decoder.
# Run as root in the guest. Needs gcc, make and linux-aarch64-headers.
set -euo pipefail

ver=$(uname -r)                    # e.g. 7.2.8-1-aarch64-ARCH
tag=v${ver%%-*}                    # v7.2.8
kdir=/usr/lib/modules/$ver/build
src=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/plain
work=${WORK:-/root/visl-build}

[ -d "$kdir" ] || { echo "no kernel headers in $kdir" >&2; exit 1; }
rm -rf "$work"; mkdir -p "$work"; cd "$work"

get() { curl -sfL --retry 5 --retry-all-errors -o "$2" "$src/$1?h=$tag" || { echo "download failed: $1" >&2; exit 1; }; }

# v4l2-tpg (test pattern generator) is not built in this kernel either.
for f in v4l2-tpg-core.c v4l2-tpg-colors.c; do
  get drivers/media/common/v4l2-tpg/$f $f
done
for f in visl-core.c visl-video.c visl-video.h visl-dec.c visl-dec.h visl.h \
         visl-trace-points.c visl-trace-h264.h visl-trace-vp8.h visl-trace-vp9.h \
         visl-trace-hevc.h visl-trace-av1.h visl-trace-fwht.h visl-trace-mpeg2.h \
         visl-debugfs.h visl-debugfs.c; do
  get drivers/media/test-drivers/visl/$f $f
done

# Trace headers point into the kernel tree; out of tree they sit next to us.
sed -i 's|^#define TRACE_INCLUDE_PATH .*|#define TRACE_INCLUDE_PATH .|' visl-trace-*.h

cat > Makefile <<'EOF'
obj-m := v4l2-tpg.o visl.o
v4l2-tpg-objs := v4l2-tpg-core.o v4l2-tpg-colors.o
visl-objs := visl-core.o visl-video.o visl-dec.o visl-trace-points.o
ccflags-y += -I$(src)
EOF

make -C "$kdir" M="$work" modules -j"$(nproc)"

modprobe videobuf2-vmalloc
modprobe v4l2-mem2mem
rmmod visl 2>/dev/null || true
rmmod v4l2-tpg 2>/dev/null || true
insmod "$work/v4l2-tpg.ko"
insmod "$work/visl.ko" ${VISL_ARGS:-}
sleep 1
v4l2-ctl --list-devices || true
