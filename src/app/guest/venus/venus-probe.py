#!/usr/bin/env python3
# venus-probe.py: what this VM's virtio-gpu offers Vulkan (Venus), from the
# kernel's virtio-gpu parameters. Prints "venus=0|1 blob_alignment=N".
# venus=1: the device has the Venus capset (OmacVM.app's Vulkan switch is on);
# blob_alignment: the size every GPU memory blob must be a multiple of (16384
# on Apple Silicon Macs; 0 when the kernel or the device do not say).
import ctypes, fcntl, glob, os, struct

GETPARAM = 0xC0106443               # DRM_IOWR(0x40 + 0x03, struct drm_virtgpu_getparam)
SUPPORTED_CAPSET_IDS, BLOB_ALIGNMENT = 7, 9
CAPSET_VENUS = 4


def getparam(fd, param):
    v = ctypes.c_int(0)
    try:
        fcntl.ioctl(fd, GETPARAM, struct.pack("QQ", param, ctypes.addressof(v)))
    except OSError:
        return None
    return v.value


venus, align = 0, 0
for node in sorted(glob.glob("/dev/dri/renderD*")):
    try:
        fd = os.open(node, os.O_RDWR | os.O_CLOEXEC)
    except OSError:
        continue
    try:
        caps = getparam(fd, SUPPORTED_CAPSET_IDS)
        if caps is not None and caps & (1 << CAPSET_VENUS):
            venus, align = 1, getparam(fd, BLOB_ALIGNMENT) or 0
            break
    finally:
        os.close(fd)
print(f"venus={venus} blob_alignment={align}")
