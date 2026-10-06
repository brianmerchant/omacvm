#!/usr/bin/env python3
"""Check an unpacked prebuilt VM bundle before anything uses it.

  bundlecheck.py ROUTE DIR NAME     ROUTE parallels|utm|fusion; DIR holds the
                                    unpacked bundle NAME.pvm|.utm|.vmwarevm

The image is untrusted until this passes. It checks:
  * the files: exactly what that route's images hold (src/prebuilt/make-image.sh
    stage_package), each a regular file with one link, real folders, no
    symbolic links or anything else;
  * the VM's settings: no path on the Mac, no folder, SSH keys, USB devices
    or network ports of the Mac, no extra QEMU arguments;
  * the disks: they read and write only their own file in the bundle (no
    backing file, no external data file, no extent elsewhere).
A link or a path in there would have Parallels, UTM or Fusion (or the disk
grow) read or write some other file on the Mac.
Exit 0 and no output when all is fine; else exit 1 and one line why.
"""
import os
import plistlib
import re
import stat
import struct
import sys
import xml.etree.ElementTree as ET

EXT = {"parallels": ".pvm", "utm": ".utm", "fusion": ".vmwarevm"}
HDS = r"omarchy\.hdd\.0\.\{[0-9a-fA-F-]{36}\}\.hds"
QCOW2 = r"[A-Za-z0-9-]{1,64}\.qcow2"
MAX_CONFIG = 4 << 20


class Bad(Exception):
    pass


def safe(s):
    """Text from the image for our message: printable ASCII, short."""
    return "".join(c if " " <= c <= "~" else "?" for c in str(s))[:120]


def tree(route, name):
    """(folders, files regex, required files) inside the bundle."""
    n = re.escape(name)
    if route == "parallels":
        return ({"", "omarchy.hdd"},
                r"config\.pvs|NVRAM\.dat|omarchy\.hdd/(DiskDescriptor\.xml|omarchy\.hdd|omarchy\.hdd\.drh|%s)" % HDS,
                ["config.pvs", "omarchy.hdd/DiskDescriptor.xml"])
    if route == "utm":
        return ({"", "Data"}, r"config\.plist|Data/(efi_vars\.fd|omacvm\.png|%s)" % QCOW2, ["config.plist"])
    return ({""}, r"omarchy\.vmdk|%s\.vmx|%s\.nvram" % (n, n), ["omarchy.vmdk", name + ".vmx"])


def check_files(route, top, bundle, name):
    folders, files, required = tree(route, name)
    files = re.compile(files)
    if os.listdir(top) != [bundle]:
        raise Bad("the archive holds more than %s" % bundle)
    # The bundle itself too: listdir() follows a link, and a link here would
    # put a VM that is already on the Mac (the user's own) in its place.
    if not stat.S_ISDIR(os.lstat(os.path.join(top, bundle)).st_mode):
        raise Bad("%s is not a folder (a link?)" % bundle)
    found = set()
    todo = [""]
    while todo:
        rel = todo.pop()
        for e in os.listdir(os.path.join(top, bundle, rel)):
            r = rel + "/" + e if rel else e
            st = os.lstat(os.path.join(top, bundle, r))
            if stat.S_ISDIR(st.st_mode) and r in folders:
                todo.append(r)
            elif stat.S_ISREG(st.st_mode) and files.fullmatch(r) and st.st_nlink == 1:
                found.add(r)
            elif stat.S_ISLNK(st.st_mode):
                raise Bad("%s is a link" % safe(r))
            elif stat.S_ISREG(st.st_mode) and st.st_nlink != 1:
                raise Bad("%s has more than one name (a hard link)" % safe(r))
            else:
                raise Bad("unexpected %s" % safe(r))
    for r in required:
        if r not in found:
            raise Bad("%s is missing" % r)
    return found


def read_small(path):
    if os.path.getsize(path) > MAX_CONFIG:
        raise Bad("%s is too big" % os.path.basename(path))
    with open(path, "rb") as f:
        return f.read()


DOTDOT = re.compile(r"(^|/)\.\.(/|$)")


def mac_path(v):
    """A value that points at a file on the Mac: absolute, or out with ..."""
    return v.startswith("/") or v.startswith("~") or DOTDOT.search(v) is not None


# ---------- Parallels ----------

def check_parallels(b, found):
    r = ET.fromstring(read_small(os.path.join(b, "config.pvs")))
    for e in r.iter():
        t = (e.text or "").strip()
        if t and mac_path(t) and t != "/dev/cu.debug-console":
            raise Bad("config.pvs names a path on the Mac (%s: %s)" % (safe(e.tag), safe(t)))
    hw = r.find("Hardware")
    if hw is None:
        raise Bad("config.pvs has no hardware")
    for h in hw.findall("Hdd"):
        if (h.findtext("SystemName") or "").strip() != "omarchy.hdd":
            raise Bad("config.pvs: a disk other than omarchy.hdd")
    if r.findall("Settings/Tools/SharedFolders/HostSharing/SharedFolder"):
        raise Bad("config.pvs shares folders of the Mac")
    for p in ("Settings/Tools/SharedFolders/HostSharing/ShareAllMacDisks",
              "Settings/Tools/SharedFolders/HostSharing/ShareUserHomeDir",
              "Settings/Tools/SharedFolders/HostSharing/SharedCloud",
              "Settings/Tools/SharedProfile/Enabled",
              "Settings/Tools/SharedVolumes/Enabled",
              "Settings/Tools/SyncSshIds"):
        if (r.findtext(p) or "0").strip() != "0":
            raise Bad("config.pvs shares the Mac's files or keys (%s)" % "/".join(p.split("/")[-2:]))
    d = ET.fromstring(read_small(os.path.join(b, "omarchy.hdd", "DiskDescriptor.xml")))
    images = d.findall("StorageData/Storage/Image")
    if not images:
        raise Bad("DiskDescriptor.xml names no disk file")
    for i in images:
        f = (i.findtext("File") or "").strip()
        if not re.fullmatch(HDS, f) or "omarchy.hdd/" + f not in found:
            raise Bad("DiskDescriptor.xml names another file (%s)" % safe(f))
        if (i.findtext("Type") or "").strip() != "Plain":
            raise Bad("DiskDescriptor.xml: not a plain disk")


# ---------- UTM ----------

def plist_values(v, where=""):
    if isinstance(v, dict):
        for k, x in v.items():
            yield from plist_values(x, where + "/" + str(k))
    elif isinstance(v, list):
        for x in v:
            yield from plist_values(x, where)
    else:
        yield where, v


def check_qcow2(path):
    with open(path, "rb") as f:
        h = f.read(104)
    if len(h) < 72 or h[:4] != b"QFI\xfb":
        raise Bad("%s is not a qcow2 disk" % os.path.basename(path))
    version, = struct.unpack(">I", h[4:8])
    backing, = struct.unpack(">Q", h[8:16])
    crypt, = struct.unpack(">I", h[32:36])
    incompat = struct.unpack(">Q", h[72:80])[0] if version >= 3 else 0
    if version not in (2, 3) or crypt:
        raise Bad("%s: unknown qcow2 version or encrypted" % os.path.basename(path))
    if backing:
        raise Bad("%s reads from another file (backing file)" % os.path.basename(path))
    # 0x1 dirty, 0x8 compression type, 0x10 extended L2; 0x4 is an external
    # data file (somewhere else on the Mac), 0x2 corrupt.
    if incompat & ~(0x1 | 0x8 | 0x10):
        raise Bad("%s uses qcow2 features OmacVM does not take (0x%x)" % (os.path.basename(path), incompat))


def check_utm(b, found):
    raw = read_small(os.path.join(b, "config.plist"))
    try:
        c = plistlib.loads(raw)
    except Exception:
        raise Bad("config.plist does not read")
    if not isinstance(c, dict):
        raise Bad("config.plist does not read")
    for where, v in plist_values(c):
        if isinstance(v, (bytes, bytearray)):
            raise Bad("config.plist holds a bookmark or data (%s)" % safe(where))
        if isinstance(v, str) and mac_path(v):
            raise Bad("config.plist names a path on the Mac (%s: %s)" % (safe(where), safe(v)))
    q = c.get("QEMU", {})
    if not isinstance(q, dict) or q.get("AdditionalArguments", []):
        raise Bad("config.plist adds QEMU arguments")
    for n in c.get("Network", []) or []:
        if isinstance(n, dict) and n.get("PortForward"):
            raise Bad("config.plist forwards ports")
    # A serial port only as a terminal on the Mac: not on a network port, not
    # QEMU's monitor or a debugger.
    for n in c.get("Serial", []) or []:
        if not isinstance(n, dict) or n.get("Mode") not in ("Ptty", "Builtin") or n.get("Target", "Auto") != "Auto":
            raise Bad("config.plist: a serial port on the network or to QEMU itself")
    drives = c.get("Drive", [])
    if not isinstance(drives, list) or not drives:
        raise Bad("config.plist has no disk")
    for d in drives:
        name = d.get("ImageName", "") if isinstance(d, dict) else ""
        if not isinstance(name, str) or not re.fullmatch(QCOW2, name) or "Data/" + name not in found:
            raise Bad("config.plist names a disk that is not in the image (%s)" % safe(name))
    for f in sorted(found):
        if f.endswith(".qcow2"):
            check_qcow2(os.path.join(b, f))


# ---------- VMware Fusion ----------

def check_vmdk(path):
    with open(path, "rb") as f:
        h = f.read(512)
        if len(h) < 64 or h[:4] != b"KDMV":
            raise Bad("omarchy.vmdk is not a single-file sparse disk")
        off, size = struct.unpack("<QQ", h[28:44])
        if not off or not size or size > 128:
            raise Bad("omarchy.vmdk: no descriptor")
        f.seek(off * 512)
        desc = f.read(size * 512).split(b"\0", 1)[0].decode("utf-8", "replace")
    extents = 0
    for line in desc.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r'(RW|RDONLY|NOACCESS)\s+\d+\s+(\S+)\s+"([^"]*)"(\s+\d+)?', line, re.I)
        kv = re.fullmatch(r'([A-Za-z0-9_.]+)\s*=\s*"?([^"]*)"?', line)
        if m:
            if m.group(2).upper() != "SPARSE" or m.group(3) != "omarchy.vmdk":
                raise Bad("omarchy.vmdk reads or writes another file (%s)" % safe(m.group(3)))
            extents += 1
        elif not kv:
            raise Bad("omarchy.vmdk: a descriptor line that does not read (%s)" % safe(line))
        else:
            # VMware's keys do not care about case. Only these, and the disk
            # data base (ddb.*): a parent, change tracking or anything else
            # could name another file.
            k, v = kv.group(1).lower(), kv.group(2).strip().lower()
            if k.startswith("parent") and (k, v) != ("parentcid", "ffffffff"):
                raise Bad("omarchy.vmdk has a parent disk")
            if k == "createtype" and v != "monolithicsparse":
                raise Bad("omarchy.vmdk is not a single-file sparse disk")
            if not k.startswith(("ddb.", "parent")) and k not in ("version", "encoding", "cid", "createtype", "isnativesnapshot"):
                raise Bad("omarchy.vmdk: unknown descriptor entry (%s)" % safe(kv.group(1)))
    if extents != 1:
        raise Bad("omarchy.vmdk: not one extent")


# Keys that make Fusion use a folder, a port or a USB device of the Mac.
VMX_REFUSED = ("sharedfolder", "hgfs.", "debugstub.", "workingdir", "extendedconfigfile",
               "checkpoint.", "suspend.", "snapshot.", "remotedisplay.", "usb.autoconnect.",
               "usb.generic.autoconnect")
VMX_ESCAPE = re.compile(r"\|([0-9A-Fa-f]{2})")
VMX_FILENAMES = {"nvme0:0.filename": "omarchy.vmdk", "sound.filename": "-1"}


def check_fusion(b, name):
    text = read_small(os.path.join(b, name + ".vmx")).decode("utf-8", "replace")
    disk = False
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r'([A-Za-z0-9_.:-]+)\s*=\s*"(.*)"', line)
        if not m:
            raise Bad("%s.vmx: a line that does not read (%s)" % (name, safe(line)))
        # Values as VMware reads them: "|2F" is "/".
        k, v = m.group(1).lower(), VMX_ESCAPE.sub(lambda e: chr(int(e.group(1), 16)), m.group(2))
        if k.startswith(VMX_REFUSED):
            raise Bad("%s.vmx uses the Mac's files or ports (%s)" % (name, safe(m.group(1))))
        if mac_path(v):
            raise Bad("%s.vmx names a path on the Mac (%s)" % (name, safe(m.group(1))))
        if k.endswith("filename"):
            if VMX_FILENAMES.get(k) != v:
                raise Bad("%s.vmx names another file (%s = %s)" % (name, safe(m.group(1)), safe(v)))
            disk = disk or k == "nvme0:0.filename"
    if not disk:
        raise Bad("%s.vmx has no omarchy.vmdk" % name)
    check_vmdk(os.path.join(b, "omarchy.vmdk"))


def main(a):
    if len(a) != 4 or a[1] not in EXT:
        sys.exit(__doc__)
    route, top, name = a[1], a[2], a[3]
    bundle = name + EXT[route]
    try:
        found = check_files(route, top, bundle, name)
        b = os.path.join(top, bundle)
        if route == "parallels":
            check_parallels(b, found)
        elif route == "utm":
            check_utm(b, found)
        else:
            check_fusion(b, name)
    except Bad as e:
        print(e)
        sys.exit(1)
    except (OSError, ET.ParseError, ValueError, struct.error) as e:
        print("the bundle does not read (%s)" % safe(type(e).__name__))
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv)
