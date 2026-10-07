#!/usr/bin/env python3
"""sheet.py RUNDIR FIRST LAST [OUT.png]: frames side by side (2x), frame number + time on each."""
import sys, os, struct
import numpy as np
from PIL import Image, ImageDraw
run, a, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
out = sys.argv[4] if len(sys.argv) > 4 else os.path.join(run, f"sheet-{a}-{b}.png")
raw = open(os.path.join(run, "cap.raw"), "rb").read(); off = 0; i = 0; tiles = []; t0 = None
while off + 24 <= len(raw):
    t, w, h, bpr, _ = struct.unpack_from("<diiii", raw, off); off += 24
    if a <= i <= b:
        im = Image.fromarray(np.frombuffer(raw, np.uint8, h * bpr, off).reshape(h, w, 4)[:, :, 2::-1].copy())
        im = im.resize((w * 2, h * 2), Image.NEAREST); d = ImageDraw.Draw(im)
        t0 = t0 or t
        d.rectangle([0, h * 2 - 22, w * 2, h * 2], fill=(0, 0, 0)); d.text((4, h * 2 - 20), f"{i} {t:.3f}", fill=(255, 255, 0))
        tiles.append(im)
    off += h * bpr; i += 1
W = sum(t.width + 4 for t in tiles); H = max(t.height for t in tiles)
cols = min(len(tiles), 10); rows = (len(tiles) + cols - 1) // cols
tw, th = tiles[0].width + 4, tiles[0].height + 4
sheet = Image.new("RGB", (cols * tw, rows * th), (40, 40, 40))
for k, t in enumerate(tiles): sheet.paste(t, ((k % cols) * tw, (k // cols) * th))
sheet.save(out); print(out)
