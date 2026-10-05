#!/usr/bin/env python3
"""Boot OmacVM.app's UEFI firmware and check what a VM sees of it.

  test-firmware.py QEMU CODE.fd LOGO.bmp

QEMU starts the firmware as OmacVM.app does (virt, HVF, virtio-gpu at
1920 x 1080, an NVMe disk with serial omacvm) but with no window, an empty
disk and fresh boot variables. Checks:
- the boot logo: the screen (QMP screendump) shows exactly LOGO.bmp's pixels,
  centred as edk2's BootLogoLib draws it; and on a 640 x 480 screen (too
  small for it) the same logo with 7-pixel cells (the biggest that fits)
  instead of none;
- the disk's boot entry: named "UEFI QEMU NVMe Ctrl omacvm 1", as QEMU's
  prebuilt firmware names it (patches/edk2-bootmanager-nvme-identify-align.patch).
Exit 0 when both hold, 1 otherwise.
"""
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time

WIDTH, HEIGHT = 1920, 1080
SMALL = (640, 480, 7)       # a screen, and the logo's cell size there (640 // 81)
NVME_ENTRY = "UEFI QEMU NVMe Ctrl omacvm 1"


def read_bmp(path):
    """A 24-bit bottom-up BMP as rows of (r, g, b) bytes."""
    data = open(path, "rb").read()
    offset, = struct.unpack_from("<I", data, 10)
    w, h, _, bits = struct.unpack_from("<iiHH", data, 18)
    if bits != 24 or h <= 0:
        raise SystemExit(f"test-firmware: {path} is not a 24-bit bottom-up BMP")
    stride = (w * 3 + 3) & ~3
    rows = []
    for y in range(h):
        line = data[offset + (h - 1 - y) * stride:][:w * 3]
        rows.append(bytes(c for i in range(0, len(line), 3) for c in line[i:i + 3][::-1]))
    return w, h, rows


def read_ppm(path):
    """QEMU's screendump (binary PPM, P6, maxval 255) as (w, h, rgb bytes)."""
    data = open(path, "rb").read()
    fields = data[:64].split(maxsplit=4)
    if len(fields) < 5 or fields[0] != b"P6" or fields[3] != b"255":
        raise ValueError("not a whole screendump")
    w, h = int(fields[1]), int(fields[2])
    pixels = data[-w * h * 3:]
    if len(data) <= w * h * 3:
        raise ValueError("not a whole screendump")
    return w, h, pixels


def smaller(logo, cell):
    """The logo with cells of CELL pixels (LOGO.bmp has 81 cells across)."""
    lw, lh, rows = logo
    big = lw // 81
    cols, nrows = lw // big, lh // big
    grid = [[rows[r * big + big // 2][(c * big + big // 2) * 3:][:3] for c in range(cols)]
            for r in range(nrows)]
    out = [b"".join(px * cell for px in line) for line in grid for _ in range(cell)]
    return cols * cell, nrows * cell, out


def logo_shown(shot, logo, size):
    w, h, pixels = shot
    lw, lh, rows = logo
    if (w, h) != size:
        return False
    x0, y0 = (w - lw) // 2, (h - lh) // 2      # BootLogoLib's centre
    for y in range(lh):
        start = ((y0 + y) * w + x0) * 3
        if pixels[start:start + lw * 3] != rows[y]:
            return False
    return True


def nvme_entries(vars_fd):
    """Descriptions of the Boot#### variables that point at an NVMe namespace."""
    data = open(vars_fd, "rb").read(0xC0000)
    found, pos = {}, data.find(b"\xaa\x55", 0x48)
    while pos != -1:
        # Authenticated variable header: StartId, State, ..., NameSize and
        # DataSize at 36, name at 60.
        state = data[pos + 2]
        name_size, data_size = struct.unpack_from("<II", data, pos + 36)
        if name_size > 1024 or data_size > 0x10000:
            pos = data.find(b"\xaa\x55", pos + 2)
            continue
        name = data[pos + 60:pos + 60 + name_size].decode("utf-16le", "replace").rstrip("\0")
        value = data[pos + 60 + name_size:pos + 60 + name_size + data_size]
        if state == 0x3F and re.fullmatch(r"Boot[0-9A-F]{4}", name):
            found[name] = value
        pos = data.find(b"\xaa\x55", (pos + 60 + name_size + data_size + 3) & ~3)
    out = []
    for value in found.values():
        # EFI_LOAD_OPTION: Attributes (4), FilePathListLength (2), then the
        # description (UTF-16, NUL-terminated) and the device path.
        end = 6
        while end + 1 < len(value) and value[end:end + 2] != b"\0\0":
            end += 2
        path = value[end + 2:]
        if b"\x03\x17\x10\x00" in path:          # messaging / NVMe namespace node
            out.append(value[6:end].decode("utf-16le", "replace"))
    return out


class QMP:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(path)
        self.buffer = b""
        self.reply()                              # greeting
        self.call("qmp_capabilities")

    def reply(self):
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("QMP closed")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            message = json.loads(line)
            if "event" not in message:
                return message

    def call(self, command, **arguments):
        self.sock.sendall(json.dumps({"execute": command, "arguments": arguments}).encode() + b"\n")
        message = self.reply()
        if "error" in message:
            raise RuntimeError(f"{command}: {message['error']}")
        return message["return"]


def boot(qemu, code, size, logo, entries):
    """Start the firmware on a size screen; wait for logo; with entries, check
    the disk's boot entry too. 0 when all is right."""
    work = tempfile.mkdtemp(prefix="omacvm-fw.")
    vars_fd = os.path.join(work, "vars.fd")
    disk = os.path.join(work, "disk.img")
    qmp_path = os.path.join(work, "qmp")
    shot_path = os.path.join(work, "screen.ppm")
    with open(vars_fd, "wb") as f:
        f.truncate(64 * 1024 * 1024)               # as a new VM's efi-vars.fd
    with open(disk, "wb") as f:
        f.truncate(16 * 1024 * 1024)
    vm = subprocess.Popen([
        qemu, "-machine", "virt,gic-version=3", "-accel", "hvf", "-cpu", "host,pmu=off",
        "-smp", "2", "-m", "1024", "-nodefaults",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={vars_fd}",
        "-drive", f"if=none,id=disk,file={disk},format=raw",
        "-device", "nvme,serial=omacvm,drive=disk,bootindex=0",
        "-device", f"virtio-gpu-pci,max_outputs=1,xres={size[0]},yres={size[1]},romfile=",
        "-display", "none", "-serial", "none", "-monitor", "none",
        "-qmp", f"unix:{qmp_path},server=on,wait=off",
    ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 30
        qmp = None
        while time.monotonic() < deadline:
            if vm.poll() is not None:
                raise SystemExit("test-firmware: QEMU stopped: " + vm.stderr.read().decode(errors="replace").strip())
            try:
                qmp = qmp or QMP(qmp_path)
                qmp.call("screendump", filename=shot_path)
            except (OSError, RuntimeError):
                # Not up yet, or no answer in time: a new connection, so that a
                # late answer is not taken for the next one.
                if qmp:
                    qmp.sock.close()
                qmp = None
                time.sleep(0.25)
                continue
            try:
                if logo_shown(read_ppm(shot_path), logo, size):
                    break
            except (OSError, ValueError):
                pass                               # no whole dump this time
            time.sleep(0.25)
        else:
            print(f"test-firmware: no {logo[0]} x {logo[1]} boot logo on the {size[0]} x {size[1]} "
                  "screen after 30 seconds", file=sys.stderr)
            return 1
        print(f"test-firmware: the firmware shows the {logo[0]} x {logo[1]} logo, centred on "
              f"{size[0]} x {size[1]}")
        if not entries:
            return 0
        # The firmware writes the boot entries after it shows the logo; then
        # QEMU stops, so the variables are all on disk.
        deadline = time.monotonic() + 15
        while not nvme_entries(vars_fd) and time.monotonic() < deadline:
            time.sleep(0.5)
        qmp.call("quit")
        vm.wait(10)
        found = nvme_entries(vars_fd)
        if found != [NVME_ENTRY]:
            print(f"test-firmware: the disk's boot entry is {found}, not [{NVME_ENTRY!r}]", file=sys.stderr)
            return 1
        print(f"test-firmware: the disk's boot entry is {NVME_ENTRY!r}")
        return 0
    finally:
        vm.kill()
        vm.wait()
        shutil.rmtree(work, ignore_errors=True)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    qemu, code, logo_path = sys.argv[1:]
    logo = read_bmp(logo_path)
    return (boot(qemu, code, (WIDTH, HEIGHT), logo, True) or
            boot(qemu, code, SMALL[:2], smaller(logo, SMALL[2]), False))


if __name__ == "__main__":
    sys.exit(main())
