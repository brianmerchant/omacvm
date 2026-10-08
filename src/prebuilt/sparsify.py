#!/usr/bin/env python3
"""Make a raw disk image sparse in place on macOS (APFS): every 1 MiB that
is all zeros becomes a hole (fcntl F_PUNCHHOLE). make-image.sh runs it on
the packed disk: dd conv=sparse alone once left a 64 GB image almost fully
allocated (62 GB), and tar then packs every zero as data, so each VM made
from the image takes 60 GB on the Mac instead of 7.

    sparsify.py FILE    prints the allocated size before and after (KiB)
"""
import fcntl, os, struct, sys

F_PUNCHHOLE = 99      # <sys/fcntl.h>
CHUNK = 1 << 20       # a multiple of the APFS block size (4 KiB)


def allocated_kib(path):
    return os.stat(path).st_blocks // 2


def punch(fd, offset, length):
    # struct fpunchhole { unsigned int fp_flags, reserved; off_t fp_offset, fp_length; }
    fcntl.fcntl(fd, F_PUNCHHOLE, struct.pack("IIqq", 0, 0, offset, length))


def main(path):
    before = allocated_kib(path)
    zero = bytes(CHUNK)
    fd = os.open(path, os.O_RDWR)
    try:
        size = os.fstat(fd).st_size
        run_start = None   # a run of zero chunks, punched as one range
        off = 0
        while off < size:
            # Skip holes that are there already (SEEK_DATA: the next data).
            try:
                nxt = os.lseek(fd, off, os.SEEK_DATA)
            except OSError:          # ENXIO: no data after off
                nxt = size
            nxt -= nxt % CHUNK      # the chunk the data starts in
            if nxt > off:
                if run_start is not None:
                    punch(fd, run_start, off - run_start); run_start = None
                off = nxt
                continue
            b = os.pread(fd, CHUNK, off)
            if b == zero[:len(b)] and len(b) == CHUNK:
                if run_start is None:
                    run_start = off
            elif run_start is not None:
                punch(fd, run_start, off - run_start); run_start = None
            off += len(b) or CHUNK
        if run_start is not None:
            punch(fd, run_start, size - run_start)
        os.fsync(fd)
    finally:
        os.close(fd)
    print(f"{before} {allocated_kib(path)}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    main(sys.argv[1])
