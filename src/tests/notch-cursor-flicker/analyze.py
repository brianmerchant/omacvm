#!/usr/bin/env python3
"""analyze.py RUNDIR : finds flicker frames in a capture (fcap .raw) using the
driver log (where the pointer is) and lines them up with the QEMU/Omanotch logs.
RUNDIR has cap.raw, cap.meta (X Y W H), drive.log, and optionally timed logs
flk-q.log / flk-o.log ("<mach seconds> <who> <what>" lines) to merge in.
Writes RUNDIR/frames.tsv, RUNDIR/events.txt, RUNDIR/flag/*.png, RUNDIR/summary.txt."""
import sys, os, re, struct, bisect
import numpy as np
from PIL import Image, ImageDraw

run = sys.argv[1]
X, Y, W, H = [float(v) for v in open(os.path.join(run, "cap.meta")).read().split()]
raw = open(os.path.join(run, "cap.raw"), "rb").read()
frames, ts, off = [], [], 0
while off + 24 <= len(raw):
    t, w, h, bpr, _ = struct.unpack_from("<diiii", raw, off); off += 24
    n = h * bpr
    if off + n > len(raw): break
    frames.append(np.frombuffer(raw, np.uint8, n, off).reshape(h, w, 4)[:, :, :3]); ts.append(t); off += n
F = np.stack(frames).astype(np.int16); ts = np.array(ts)
nf, fh, fw, _ = F.shape

# pointer track from the driver log
mv = []
for l in open(os.path.join(run, "drive.log")):
    m = re.match(r"([\d.]+) D move (-?[\d.]+),(-?[\d.]+)", l)
    if m: mv.append((float(m[1]), float(m[2]) - X, float(m[3]) - Y))
mt = [m[0] for m in mv]
def pos_at(t):
    i = bisect.bisect_right(mt, t) - 1
    return mv[max(i, 0)][1:] if mv else (None, None)
def span(t, back, fwd):
    pts = [pos_at(t - back)] + [m[1:] for m in mv if t - back <= m[0] <= t + fwd] + [pos_at(t + fwd)]
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    return min(xs), max(xs), min(ys), max(ys)

# background: per-pixel median of frames sampled across the run
# leaving out a box around where the driver had the pointer in each frame: a
# pointer that rests on two spots half of the time each would else be part of
# the background, and its absence would look like a stray cursor
sample = list(range(0, nf, max(1, nf // 120)))
hide = np.zeros((len(sample), fh, fw), bool)
for k, i in enumerate(sample):
    x0, x1, y0, y1 = span(ts[i], 0.060, 0.030)
    if x0 is not None:
        hide[k, max(0, int(y0) - 8):int(y1) + 34, max(0, int(x0) - 8):int(x1) + 30] = True
masked = np.ma.masked_array(F[sample], np.repeat(hide[:, :, :, None], 3, axis=3))
bg = np.ma.median(masked, axis=0).filled(0)
diff = np.abs(F - bg).sum(axis=3) > 90

def clusters(mask):
    """Rough blobs: split by empty columns, then empty rows."""
    out = []
    cols = np.where(mask.any(axis=0))[0]
    if not len(cols): return out
    groups = np.split(cols, np.where(np.diff(cols) > 6)[0] + 1)
    for g in groups:
        sub = mask[:, g[0]:g[-1] + 1]
        rows = np.where(sub.any(axis=1))[0]
        for r in np.split(rows, np.where(np.diff(rows) > 6)[0] + 1):
            px = int(sub[r[0]:r[-1] + 1].sum())
            out.append((int(g[0]), int(r[0]), int(g[-1]), int(r[-1]), px))
    return out

# only frames once the crossings started (not the move into place before)
steps = [float(l.split()[0]) for l in open(os.path.join(run, "drive.log")) if " D step " in l]
t_start = steps[0] if steps else ts[0]

rows, flagged = [], []
for i in range(nf):
    t = ts[i]
    if t < t_start:
        rows.append((i, t, None, None, 0, 0, "", ""))
        continue
    # where the cursor may be drawn now: the guest draws its pointer about
    # 50 ms behind the hand (Air, slow moves over the VM: median 48 ms, max
    # 68 ms), so a cursor where the hand was within the last 70 ms is live
    x0, x1, y0, y1 = span(t, 0.070, 0.010)
    bl = clusters(diff[i])
    live = [b for b in bl if b[0] <= x1 + 22 and b[2] >= x0 - 6 and b[1] <= y1 + 26 and b[3] >= y0 - 6]
    stray = [b for b in bl if b not in live and b[4] >= 25]
    livepx = sum(b[4] for b in live)
    kind = []
    if livepx < 25: kind.append("MISSING")
    if stray: kind.append("STRAY")
    if live and max(b[2] - b[0] for b in live) > 34 and (x1 - x0) < 8: kind.append("WIDE")
    # two arrows one above the other, touching (a stale guest arrow right
    # below the strip's edge and the Mac's on the strip): one blob, too tall
    if live and max(b[3] - b[1] for b in live) > 34 and (y1 - y0) < 8: kind.append("TALL")
    px, py = pos_at(t)
    rows.append((i, t, px, py, livepx, len(live), ";".join(f"{b[0]},{b[1]},{b[2]},{b[3]},{b[4]}" for b in stray), "|".join(kind)))
    if kind: flagged.append(i)

with open(os.path.join(run, "frames.tsv"), "w") as f:
    f.write("frame\tt\tpx\tpy\tlivepx\tnlive\tstray\tkind\n")
    for r in rows: f.write("\t".join(str(v) if not isinstance(v, float) else f"{v:.4f}" for v in r) + "\n")

# merged event log
ev = []
for name in ("drive.log", "flk-q.log", "flk-o.log"):
    p = os.path.join(run, name)
    if os.path.exists(p):
        for l in open(p):
            m = re.match(r"([\d.]+) (\S) (.*)", l.rstrip())
            if m and not (m[2] == "D" and " move " in " " + m[3] and False): ev.append((float(m[1]), m[2], m[3]))
ev.sort()
with open(os.path.join(run, "events.txt"), "w") as f:
    fi = 0
    for t, who, what in ev:
        if who == "Q" and what.split(" ", 2)[1:2] and "tablet" in what: continue
        if who == "D" and what.startswith("move"): continue
        while fi < nf and ts[fi] <= t:
            r = rows[fi]
            if r[7]: f.write(f"{ts[fi]:.4f} F frame {fi} {r[7]} live={r[4]} stray={r[6]}\n")
            fi += 1
        f.write(f"{t:.4f} {who} {what}\n")

os.makedirs(os.path.join(run, "flag"), exist_ok=True)
for i in flagged[:400]:
    im = Image.fromarray(F[i][:, :, ::-1].astype(np.uint8)).resize((fw * 2, fh * 2), Image.NEAREST)
    d = ImageDraw.Draw(im); px, py = pos_at(ts[i])
    if px is not None: d.rectangle([px * 2 - 3, py * 2 - 3, px * 2 + 3, py * 2 + 3], outline=(255, 0, 255))
    d.text((4, 4), f"{i} {rows[i][7]}", fill=(255, 0, 255))
    im.save(os.path.join(run, "flag", f"f{i:05d}.png"))
from collections import Counter
c = Counter(k for r in rows for k in r[7].split("|") if k)
dur = ts[-1] - ts[0] if nf > 1 else 0
# the longest stretch of frames in a row that are wrong (a frame of render latency at a crossing is 1)
# and how long it showed (until the next good frame; the capture only gets a
# frame when the screen changes)
longest = run_len = 0
longest_ms = 0.0
first = None
for i in range(nf):
    if rows[i][7]:
        run_len += 1
        first = ts[i] if first is None else first
    else:
        if first is not None:
            longest_ms = max(longest_ms, (ts[i] - first) * 1000)
        run_len, first = 0, None
    longest = max(longest, run_len)
with open(os.path.join(run, "summary.txt"), "w") as f:
    f.write(f"frames {nf} over {dur:.1f} s ({nf / dur if dur else 0:.1f} fps), flagged {len(flagged)}: {dict(c)}"
            f", longest {longest} frames / {longest_ms:.0f} ms\n")
print(open(os.path.join(run, "summary.txt")).read(), end="")
