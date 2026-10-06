#!/usr/bin/env python3
"""The start animation of OmacVM.app's window (omacvm-cocoa-boot-splash.patch):
OMACVM turns into Omarchy's logo. O, M and A stay and drift 2.5 cells left;
every cell of C, V and M flies (shrinking to a dot on the way) and lands as a
cell of R, C, H or Y, left to right. This is the preview the user picked from
three ("pixel morph"); its generator (numpy) ported to plain Python, so the
build needs nothing else: same letters, same pairing, same random numbers.
The starts are the preview's seconds; the app plays them slower
(omacvm-splash.h: INTRO_HOLD, INTRO_SLOW).

Input is the logo's cells as ui/omacvm-splash.h has them (omacvm_splash_cells,
the firmware's logo). Output is the table that header carries:

  make-splash-morph.py ui/omacvm-splash.h            print the C table
  make-splash-morph.py --check ui/omacvm-splash.h    exit 1 if its table differs

Units are logo cells, x to the right and y down from the logo's top left;
the arc is how far a cell rises (negative) or falls at mid-flight.
"""
import random
import re
import struct
import sys

# V in the style of the logo (Omarchy's logo has no V): top like its Y and H,
# 3-cell stems, a stepped point.
V_GLYPH = """
.........
..#...#..
.##...##.
###...###
###...###
###...###
###...###
###...###
###...###
###...###
###...###
###...###
.###.###.
.###.###.
..#####..
..#####..
...###...
"""
# OMACVM keeps O, M and A where the logo has them and spaces C, V and M as the
# logo spaces its letters; the word is 76 cells wide, the logo 81, so OMACVM
# sits 2.5 cells right of the logo when both are centred.
OMACVM = [("O", 0), ("M", 11), ("A", 27), ("C", 39), ("V", 50), ("M", 61)]
SHIFT = (81 - 76) / 2
SEED = 7


def f32(v):
    """Round to the float32 the previews computed in (numpy)."""
    return struct.unpack("f", struct.pack("f", v))[0]


def read_cells(path):
    src = open(path, encoding="utf-8").read()
    m = re.search(r"omacvm_splash_cells\[SPLASH_ROWS\]\[SPLASH_COLS \+ 1\] = \{(.*?)\};", src, re.S)
    if not m:
        raise SystemExit("make-splash-morph: no omacvm_splash_cells in " + path)
    return [[c == "#" for c in r] for r in re.findall(r'"([#.]+)"', m.group(1))], src


def letters(grid):
    """8-connected parts of the logo, left to right: O M A R C H Y."""
    rows, cols = len(grid), len(grid[0])
    seen, comps = set(), []
    for r in range(rows):
        for c in range(cols):
            if grid[r][c] and (r, c) not in seen:
                stack, comp = [(r, c)], []
                seen.add((r, c))
                while stack:
                    y, x = stack.pop()
                    comp.append((y, x))
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            ny, nx = y + dy, x + dx
                            if (0 <= ny < rows and 0 <= nx < cols and grid[ny][nx]
                                    and (ny, nx) not in seen):
                                seen.add((ny, nx))
                                stack.append((ny, nx))
                comps.append(comp)
    comps.sort(key=lambda cs: min(c for _, c in cs))
    if len(comps) != 7:
        raise SystemExit("make-splash-morph: expected 7 letters, found %d" % len(comps))
    out = {}
    for name, comp in zip("OMARCHY", comps):
        c0 = min(c for _, c in comp)
        out[name] = (c0, [(r, c - c0) for r, c in comp])
    return out


def morph(grid):
    """keep_cols: O, M and A are the logo's cells left of it; parts: [(sx, sy,
    dx, dy, delay, arc)]."""
    lets = letters(grid)
    glyph = {k: v[1] for k, v in lets.items()}
    lines = V_GLYPH.strip("\n").splitlines()
    glyph["V"] = [(r, c) for r, line in enumerate(lines) for c, ch in enumerate(line) if ch == "#"]
    omarchy = [(k, lets[k][0]) for k in "OMARCHY"]

    def cells_of(word, idx, shift):
        return [(col + c + shift, r) for i, (name, col) in enumerate(word) if i in idx
                for r, c in glyph[name]]

    keep_s = cells_of(OMACVM, range(0, 3), SHIFT)
    keep_t = cells_of(omarchy, range(0, 3), 0)
    if [(x - SHIFT, y) for x, y in keep_s] != keep_t:
        raise SystemExit("make-splash-morph: OMACVM's O, M, A are not the logo's")
    src = cells_of(OMACVM, range(3, 6), SHIFT)
    dst = cells_of(omarchy, range(3, 7), 0)

    def norm(p):
        lo = [min(v[k] for v in p) for k in (0, 1)]
        hi = [max(v[k] for v in p) for k in (0, 1)]
        return [tuple(f32((v[k] - lo[k]) / max(hi[k] - lo[k], 1)) for k in (0, 1)) for v in p]

    ns, nd = norm(src), norm(dst)

    def d2(a, b):
        return f32(f32(f32(a[0] - b[0]) ** 2) + f32(f32(a[1] - b[1]) ** 2))

    def argmin(vals):
        best = 0
        for i, v in enumerate(vals):
            if v < vals[best]:
                best = i
        return best

    pairs = [(argmin([d2(nd[j], s) for s in ns]), j) for j in range(len(dst))]
    used = {i for i, _ in pairs}
    pairs += [(i, argmin([d2(d, ns[i]) for d in nd])) for i in range(len(src)) if i not in used]
    rnd = random.Random(SEED)
    parts = []
    for i, j in pairs:
        delay = 0.55 + 0.7 * nd[j][0] + rnd.uniform(0, 0.12)
        arc = rnd.uniform(-70, 25) / 10   # the previews' pixels; 10 per cell
        parts.append((src[i][0], src[i][1], dst[j][0], dst[j][1], delay, arc))
    keep_cols = lets["R"][0]
    if max(x for x, _ in keep_t) >= keep_cols:
        raise SystemExit("make-splash-morph: A reaches into R's columns")
    return keep_cols, parts


def table(keep_cols, parts):
    out = ["/* Made by boot-logo/make-splash-morph.py; the build checks it. */",
           "#define MORPH_KEEP_COLS %d  /* O, M and A: the logo's cells left of this column */"
           % keep_cols,
           "#define MORPH_PARTS %d" % len(parts),
           "/* The flying cells: from (x, y) in OMACVM to (x, y) in the logo, start (s of the",
           "   preview), arc. */",
           "static const float omacvm_morph_parts[MORPH_PARTS][6] = {"]
    for k in range(0, len(parts), 3):
        out.append("    " + " ".join("{%.1ff, %d, %d, %d, %.4ff, %.4ff}," % p
                                      for p in parts[k:k + 3]))
    out.append("};")
    return "\n".join(out)


def main():
    args = sys.argv[1:]
    check = args[:1] == ["--check"]
    if check:
        args = args[1:]
    if len(args) != 1:
        raise SystemExit(__doc__)
    grid, src = read_cells(args[0])
    text = table(*morph(grid))
    if not check:
        print(text)
        return
    if text not in src:
        print("make-splash-morph: the morph table in %s is not the generator's" % args[0],
              file=sys.stderr)
        sys.exit(1)
    print("make-splash-morph: the morph table matches")


if __name__ == "__main__":
    main()
