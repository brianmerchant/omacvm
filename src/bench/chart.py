#!/usr/bin/env python3
"""docs/images/benchmarks.svg from a results JSON: each route as a share of the Mac.

  chart.py [--panel gpu] docs/benchmarks/chart.json docs/images/benchmarks.svg "MacBook Pro M4 Max · macOS 15.7 · Chrome 154"

The JSON is report.py's ("medians", "missing"), plus optional "unreleased":
{route: [test, ...]} for numbers from a build that is not out yet, or
{route: {test: tag}} to name it (say "2.9.0 RC"). Those bars are striped and
tagged ("not released" without a name). An optional "note" (a string, or a
list for several lines) replaces the line under the chart. Tests without a Mac
value are left out.

--panel gpu [--aquarium] draws the GPU panel instead (tests/bench/final-round,
summarize.py's JSON): GPU throughput first (with the timing method from
"methods"), GPU compute (vkpeak, Geekbench OpenCL and Vulkan), glmark2 and
vkmark (VMs only, scores), Basemark, and Aquarium with --aquarium; macOS =
100 %. A route without a number gets an empty hatched bar with the reason from
"missing". "placeholder": true in the JSON marks the whole chart as made-up
data (for drafts), "preliminary": true (summarize.py) as not from the agreed
quiet Mac.

--panel power draws docs/images/power.svg from the JSON's "power" part: the
whole Mac's draw in watts per load (lower is better) and the battery hours, a
bar per route and one for macOS, each load on its own scale; below it a
second round ("round") of OmacVM.app against macOS on one scale.
"""
import json, sys
from xml.sax.saxutils import escape

FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"
INK, SOFT, MUTED, BG = "#e0def4", "#908caa", "#6e6a86", "#191724"
ROUTES = [  # report.py names (file names), label, colour; the app first
    ("app", "OmacVM.app", "#ebbcba"),
    ("utm", "UTM", "#c4a7e7"),
    ("fusion", "VMware Fusion", "#f6c177"),
    ("parallels", "Parallels", "#9ccfd8"),
]
TESTS = [
    ("geekbench-cpu-multi", "CPU, all cores", "Geekbench 7"),
    ("speedometer", "Web apps", "Speedometer 3.1"),
    ("aquarium", "Browser graphics", "WebGL Aquarium"),
    ("basemark", "Browser overall", "Basemark Web 3.0"),
    ("geekbench-gpu-opencl", "GPU compute", "Geekbench 7 GPU, OpenCL"),
]
NOTE = "Striped: not released yet (OmacVM.app with Vulkan in the VM). glmark2 and vkmark have no macOS version: see docs/benchmarks."


def text(x, y, s, size=12, fill=INK, font=FONT, weight=None, anchor=None, halo=False):
    w = f' font-weight="{weight}"' if weight else ""
    a = f' text-anchor="{anchor}"' if anchor else ""
    h = f' stroke="{BG}" stroke-width="4" paint-order="stroke"' if halo else ""
    return f'<text x="{x}" y="{y}" font-family="{font}" font-size="{size}" fill="{fill}"{w}{a}{h}>{escape(s)}</text>'


def textw(s, size):
    """Rough width of s in the sans font, enough to space a legend."""
    return sum(0.28 if c in "ilt.,:;|' " else 0.68 if c.isupper() or c in "mw%" else 0.55 for c in s) * size


def monow(s, size):
    """Width of s in the monospaced font."""
    return 0.62 * size * len(s)


def main():
    args = sys.argv[1:]
    if args[:2] == ["--panel", "gpu"]:
        return gpu_panel(*args[2:])
    if args[:2] == ["--panel", "power"]:
        return power_panel(*args[2:])
    data = json.load(open(args[0]))
    out, subtitle = args[1], args[2] if len(args) > 2 else ""
    med, missing = data["medians"], data.get("missing", {})
    unrel = {}  # (route, test) -> tag on the bar
    for r, ts in data.get("unreleased", {}).items():
        for t in ts:
            unrel[(r, t)] = ts[t] if isinstance(ts, dict) else "not released"
    note = data.get("note", NOTE)
    notes = [note] if isinstance(note, str) else note
    mac = med.get("mac", {})
    routes = [r for r in ROUTES if r[0] in med]
    tests = [t for t in TESTS if mac.get(t[0]) and any(t[0] in med[r[0]] or t[0] in missing.get(r[0], {}) for r in routes)]

    W, left, full = 1000, 230, 620          # full = width of 100 % (the Mac)
    pitch, bar, gap, top = 15, 11, 16, 104
    group = len(routes) * pitch
    H = top + len(tests) * (group + gap) + 14 + 16 * len(notes)

    def share(name, key):
        v = med.get(name, {}).get(key)
        return None if v is None else 100 * v / mac[key]

    desc = []
    for key, label, bench in tests:
        parts = []
        for name, rl, _ in routes:
            p = share(name, key)
            if p is None:
                parts.append(f"{rl} {missing.get(name, {}).get(key, 'not available')}")
            else:
                tag = unrel.get((name, key))
                parts.append(f"{rl} {round(p)} percent" + (f" ({'not released yet' if tag == 'not released' else tag})" if tag else ""))
        desc.append(f"{label} ({bench}): " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">How fast Omarchy runs in OmacVM.app, UTM, VMware Fusion and Parallels, as a share of macOS itself</title>',
         f'<desc id="d">{escape(". ".join(desc))}. macOS itself is 100 percent.</desc>',
         '<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern>']
    for name, _, col in routes:
        s.append(f'<pattern id="hatch-{name}" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
                 f'<rect width="6" height="6" fill="{col}" fill-opacity="0.25"/><rect width="3" height="6" fill="{col}"/></pattern>')
    s.append('</defs>')
    s.append(f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>')
    s.append(text(W / 2, 34, "How fast is Omarchy in a VM?", 20, weight="600", anchor="middle"))
    s.append(text(W / 2, 56, subtitle, 13, SOFT, anchor="middle"))

    # legend, centred: the routes in chart order, then the Mac's line
    items = [(rl, col) for _, rl, col in routes] + [("macOS = 100 %", None)]
    widths = [18 + textw(rl, 13) + 22 for rl, _ in items]
    x = (W - sum(widths) + 22) / 2
    for (rl, col), w in zip(items, widths):
        if col:
            s.append(f'<rect x="{x:.0f}" y="69" width="12" height="12" rx="3" fill="{col}"/>')
        else:
            s.append(f'<line x1="{x + 6:.0f}" y1="67" x2="{x + 6:.0f}" y2="83" stroke="{INK}" stroke-opacity="0.6" stroke-dasharray="3 3"/>')
        s.append(text(f"{x + 18:.0f}", 80, rl, 13, weight="600" if rl == routes[0][1] else None))
        x += w

    # the Mac: one dashed line at 100 % through every row, behind the bars
    s.append(f'<line x1="{left + full}" y1="{top - 4}" x2="{left + full}" y2="{top + len(tests) * (group + gap) - gap + 4}" stroke="{INK}" stroke-opacity="0.45" stroke-dasharray="3 3"/>')
    y = top
    for key, label, bench in tests:
        s.append(text(40, y + group / 2 - 3, label, 15, weight="600"))
        s.append(text(40, y + group / 2 + 14, bench, 12, MUTED))
        for i, (name, rl, col) in enumerate(routes):
            by = y + i * pitch
            p = share(name, key)
            if p is None:
                s.append(text(left, by + 10, f"– {rl}: " + missing.get(name, {}).get(key, "not available"), 11, MUTED, MONO))
                continue
            w = max(2, min(full * 1.1, full * p / 100))
            fill = f"url(#hatch-{name})" if (name, key) in unrel else col
            s.append(f'<rect x="{left}" y="{by + (pitch - bar) / 2:.1f}" width="{w:.1f}" height="{bar}" rx="3" fill="{fill}"/>')
            tx = left + w + 8
            if tx - 8 < left + full < tx + 40:  # keep the Mac's line out from behind the value
                s.append(f'<rect x="{left + w + 1:.1f}" y="{by}" width="52" height="{pitch}" fill="{BG}"/>')
            s.append(text(f"{tx:.1f}", by + 11, f"{round(p)} %", 12, INK, MONO, "600" if name == routes[0][0] else None, halo=True))
            if (name, key) in unrel:
                tag = unrel[(name, key)]
                tw = textw(tag, 10) + 28
                s.append(f'<rect x="{tx + 42:.1f}" y="{by + 1}" width="{tw:.0f}" height="13" rx="6.5" fill="none" stroke="{col}" stroke-opacity="0.7"/>')
                s.append(text(f"{tx + 42 + tw / 2:.1f}", by + 11, tag, 10, col, anchor="middle"))
        y += group + gap
    for i, line in enumerate(notes):
        s.append(text(W / 2, H - 14 - 16 * (len(notes) - 1 - i), line, 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


GPU_TESTS = [  # key, label, benchmark, headline, the Mac's key ("" = no macOS version: absolute scores)
    ("gpu-throughput", "GPU throughput", "WebGL 2 ray march, offscreen 1080p", True, "gpu-throughput"),
    ("vkpeak-fp32", "GPU compute", "vkpeak fp32, Vulkan (macOS: MoltenVK 1.4.1)", False, "vkpeak-fp32"),
    ("geekbench-gpu-opencl", "GPU compute", "Geekbench 7 GPU, OpenCL", False, "geekbench-gpu-opencl"),
    ("geekbench-gpu-vulkan", "GPU compute", "Geekbench 7 GPU, Vulkan (macOS: Metal)", False, "geekbench-gpu-metal"),
    ("glmark2", "OpenGL in the VM", "glmark2, no macOS version: score", False, ""),
    ("vkmark", "Vulkan in the VM", "vkmark, no macOS version: score", False, ""),
    ("basemark", "Browser graphics", "Basemark Web 3.0", False, "basemark"),
    ("aquarium", "Browser 3D", "WebGL Aquarium, 30,000 fish", False, "aquarium"),
]
METHOD = {"timer": "GPU time (timer query)", "wall": "wall time, long frames"}


def wrap(s, size, width):
    """s in at most two lines that fit width (roughly), split between words."""
    if textw(s, size) <= width:
        return [s]
    words, first = s.split(" "), ""
    while words and textw((first + " " + words[0]).strip(), size) <= width:
        first = (first + " " + words.pop(0)).strip()
    return [first, " ".join(words)] if first else [s]


def gpu_panel(*args):
    """The GPU panel: one group per test, a bar per route, macOS = 100 %.

    Rows with no macOS version (glmark2, vkmark) show each VM's score, bars
    scaled to the best VM. Aquarium only with --aquarium (optional row)."""
    aquarium = "--aquarium" in args
    args = [x for x in args if x != "--aquarium"]
    src, out, subtitle = args[0], args[1], args[2] if len(args) > 2 else ""
    data = json.load(open(src))
    med, missing = data["medians"], data.get("missing", {})
    mac = med.get("mac", {})
    placeholder = data.get("placeholder", False)
    banner = ("PLACEHOLDER DATA: made-up numbers to show the layout. Not measured." if placeholder else
              "PRELIMINARY: not from the agreed quiet Mac, not the final round." if data.get("preliminary") else None)
    # A second app build (summarize.py's "app-rc2", e.g. a 3.0.0 RC with Vulkan) sits under the app, only in
    # the rows it has a number or a reason for. "labels" names the builds ("OmacVM 2.9.1").
    labels = data.get("labels", {})
    routes = [(n, labels.get(n, rl), c) for n, rl, c in ROUTES[:1] + [("app-rc2", "OmacVM.app (second build)", "#eb6f92")] + ROUTES[1:]
              if n in med or n in missing]
    tests = []
    for key, label, bench, headline, base in GPU_TESTS:
        if key == "aquarium" and not aquarium:
            continue
        if base and not mac.get(base):
            continue
        if not base and not any(med.get(n, {}).get(key) for n, _, _ in routes):
            continue
        m = data.get("methods", {}).get(key, {}).get("method")
        if key == "glmark2" and data.get("glmark2_scene_seconds") not in (None, 10):   # shorter scenes than glmark2's own
            bench += f" · {data['glmark2_scene_seconds']:g} s scenes"
        tests.append((key, label, bench + (f" · {METHOD[m]}" if m in METHOD else ""), headline, base))

    def row_routes(key):
        return [r for r in routes if r[0] != "app-rc2" or key in med.get("app-rc2", {}) or key in missing.get("app-rc2", {})]

    W, left, full = 1000, 250, 560
    pitch, bar, gap, top = 22, 14, 26, 112
    H = top + sum(len(row_routes(t[0])) * pitch + gap for t in tests) + (58 if banner else 34)

    def share(name, key, base):
        v = med.get(name, {}).get(key)
        if v is None:
            return None
        if base:
            return 100 * v / mac[base]
        best = max(med.get(n, {}).get(key) or 0 for n, _, _ in row_routes(key))
        return 100 * v / best

    def why(name, key):
        return missing.get(name, {}).get(key, "not available")

    desc = []
    for key, label, bench, _, base in tests:
        parts = []
        for n, rl, _ in row_routes(key):
            v = med.get(n, {}).get(key)
            parts.append(f"{rl} {why(n, key)}" if v is None else f"{rl} {round(share(n, key, base))} percent" if base
                         else f"{rl} score {v:g}")
        desc.append(f"{label} ({bench}): " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">GPU speed of Omarchy in OmacVM.app, UTM, VMware Fusion and Parallels, as a share of macOS itself</title>',
         f'<desc id="d">{banner + " " if banner else ""}{escape(". ".join(desc))}. macOS itself is 100 percent.</desc>',
         '<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern>',
         f'<pattern id="na" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="2" height="8" fill="{MUTED}" fill-opacity="0.35"/></pattern>',
         '</defs>',
         f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
         text(W / 2, 34, "How fast is the GPU in a VM?", 20, weight="600", anchor="middle"),
         text(W / 2, 56, subtitle, 13, SOFT, anchor="middle")]

    items = [(rl, col) for _, rl, col in routes] + [("macOS = 100 %", None)]
    widths = [18 + textw(rl, 13) + 22 for rl, _ in items]
    x = (W - sum(widths) + 22) / 2
    for (rl, col), w in zip(items, widths):
        if col:
            s.append(f'<rect x="{x:.0f}" y="69" width="12" height="12" rx="3" fill="{col}"/>')
        else:
            s.append(f'<line x1="{x + 6:.0f}" y1="67" x2="{x + 6:.0f}" y2="83" stroke="{INK}" stroke-opacity="0.6" stroke-dasharray="3 3"/>')
        s.append(text(f"{x + 18:.0f}", 80, rl, 13, weight="600" if rl == routes[0][1] else None))
        x += w

    bottom = top + sum(len(row_routes(t[0])) * pitch + gap for t in tests) - gap
    y = top
    for key, label, bench, headline, base in tests:
        rr = row_routes(key)
        group = len(rr) * pitch
        if headline:   # the headline row sits on a faint band
            s.append(f'<rect x="24" y="{y - 8}" width="{W - 48}" height="{group + 16}" rx="8" fill="{INK}" fill-opacity="0.04"/>')
        if base:   # macOS = 100 %, only where macOS has the test
            s.append(f'<line x1="{left + full}" y1="{y - 6}" x2="{left + full}" y2="{y + group + 2}" stroke="{INK}" stroke-opacity="0.45" stroke-dasharray="3 3"/>')
        lines = wrap(bench, 12, left - 50)   # the benchmark under the label, on two lines if long
        ly = y + group / 2 - 4 - 7 * (len(lines) - 1)
        s.append(text(40, ly, label, 16 if headline else 15, weight="600"))
        for j, ln in enumerate(lines):
            s.append(text(40, ly + 18 + 15 * j, ln, 12, MUTED))
        for i, (name, rl, col) in enumerate(rr):
            by = y + i * pitch + (pitch - bar) / 2
            p = share(name, key, base)
            if p is None:   # an empty bar to 100 %, hatched, with the reason
                s.append(f'<rect x="{left}" y="{by:.1f}" width="{full}" height="{bar}" rx="4" fill="url(#na)" stroke="{MUTED}" stroke-opacity="0.5" stroke-dasharray="4 3"/>')
                s.append(text(left + 10, by + 11, f"{rl}: {why(name, key)}", 11, SOFT, halo=True))
                continue
            w = max(3, min(full * 1.15, full * p / 100))
            s.append(f'<rect x="{left}" y="{by:.1f}" width="{w:.1f}" height="{bar}" rx="4" fill="{col}"/>')
            tx = left + w + 8
            if base and tx - 8 < left + full < tx + 140:  # keep the Mac's line out from behind the label
                s.append(f'<rect x="{left + w + 1:.1f}" y="{by - 3:.1f}" width="150" height="{bar + 6}" fill="{BG}"/>')
            first = name == routes[0][0]
            num = f"{round(p)} %" if base else f"{med[name][key]:g}"
            s.append(text(f"{tx:.1f}", by + 11.5, num, 13, INK, MONO, "600" if first else None, halo=True))
            lx = tx + 10 + textw(num, 13)
            if lx + textw(rl, 11) > W - 12 and w > textw(rl, 11) + 16:   # no room right of a long bar: inside its end
                s.append(text(f"{left + w - 8:.1f}", by + 11, rl, 11, BG, weight="600", anchor="end"))
            else:
                s.append(text(f"{lx:.1f}", by + 11.5, rl, 11, SOFT, halo=True))
        y += group + gap
    if banner:
        s.append(f'<rect x="24" y="{H - 44}" width="{W - 48}" height="28" rx="6" fill="#eb6f92" fill-opacity="0.15" stroke="#eb6f92"/>')
        s.append(text(W / 2, H - 25, banner, 13, "#eb6f92", weight="600", anchor="middle"))
    if placeholder:
        s.append(f'<text x="{W / 2}" y="{(top + bottom) / 2}" font-family="{FONT}" font-size="64" font-weight="700" fill="#eb6f92" fill-opacity="0.10" text-anchor="middle" transform="rotate(-12 {W / 2} {(top + bottom) / 2})">PLACEHOLDER</text>')
    if not banner:
        s.append(text(W / 2, H - 14, data.get("note", "Each VM as a share of macOS on the same Mac. Hatched: no number, with the reason."), 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


POWER_LOADS = [  # key, label, what runs
    ("idle", "Idle", "the desktop, nothing open"),
    ("light", "Reading", "Chrome scrolling a text page"),
    ("video", "YouTube 4K", "Chrome, SDR; macOS decodes in hardware, the VMs on the CPU"),
    ("cpu", "Every core busy", "all CPU cores at 100 %"),
    ("gpu", "WebGL Aquarium", "30,000 fish in Chrome; each draws its own frame rate"),
]
MACOS = ("mac", "macOS", SOFT)


def power_panel(src, out, subtitle=""):
    """The power chart: watts of the whole Mac per load (lower is better) and hours on a full battery.

    Top: one round, a bar per route and one for macOS, each load scaled to its
    own largest draw. Below: "round", OmacVM.app against macOS on other Macs,
    one scale for all its rows."""
    data = json.load(open(src))["power"]
    watts, missing, wh = data["watts"], data.get("missing", {}), data["battery_wh"]
    labels = data.get("labels", {})  # e.g. {"app": "OmacVM.app preview"}: the build the round ran
    routes = [(n, labels.get(n, rl), c) for n, rl, c in ROUTES if n in watts or n in missing] + [MACOS]
    loads = [l for l in POWER_LOADS if any(l[0] in watts.get(r[0], {}) for r in routes)]
    rnd = data.get("round")
    rows = rnd["rows"] if rnd else []
    rapp = rnd.get("app_label", "OmacVM.app") if rnd else ""
    app_col = ROUTES[0][2]

    def fmt(v, cap, digits=1):
        return f"{v:.{digits}f} W", f"{cap / v:.1f} h"

    W, left, full = 1000, 250, 480
    pitch, bar, gap, top = 22, 14, 26, 128
    rgap, rpitch = 22, 22
    main_h = len(loads) * (len(routes) * pitch + gap) - gap
    round_top = top + main_h + 60
    round_h = len(rows) * (2 * rpitch + rgap) - rgap if rows else 0
    notes = data.get("note", [])
    notes = [notes] if isinstance(notes, str) else notes
    H = (round_top + 34 + round_h if rows else top + main_h) + 28 + 16 * len(notes)

    desc = []
    for key, label, what in loads:
        parts = []
        for name, rl, _ in routes:
            v = watts.get(name, {}).get(key)
            if v is None:
                parts.append(f"{rl} {missing.get(name, {}).get(key, 'not measured')}")
            else:
                w, h = fmt(v, wh)
                parts.append(f"{rl} {w} ({h})")
        desc.append(f"{label} ({what}): " + ", ".join(parts))
    for r in rows:
        parts = []
        for rl, v in ((rapp, r["app"]), ("macOS", r.get("macos"))):
            if v is None:
                parts.append(f"{rl} {r.get('macos_missing', 'not measured')}")
            else:
                w, h = fmt(v, r["wh"], 2)
                parts.append(f"{rl} {w} ({h})")
        desc.append(f"{r['mac']}, {dict((k, l) for k, l, _ in POWER_LOADS)[r['load']]}: " + ", ".join(parts))

    s = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="t d">',
         '<title id="t">Power draw of the whole Mac with Omarchy in OmacVM.app, UTM, VMware Fusion and Parallels, and macOS itself</title>',
         f'<desc id="d">{escape(". ".join(desc))}. Watts, lower is better; hours on a full battery.</desc>',
         '<defs><pattern id="dots" width="40" height="40" patternUnits="userSpaceOnUse"><rect x="20" y="20" width="2" height="2" fill="#26233a"/></pattern></defs>',
         f'<rect width="{W}" height="{H}" fill="{BG}"/><rect width="{W}" height="{H}" fill="url(#dots)"/>',
         text(W / 2, 34, "How much power does the Mac draw?", 20, weight="600", anchor="middle"),
         text(W / 2, 56, subtitle, 13, SOFT, anchor="middle")]

    items = [(rl, col) for _, rl, col in routes]
    widths = [18 + textw(rl, 13) + 22 for rl, _ in items]
    x = (W - sum(widths) + 22) / 2
    for (rl, col), w in zip(items, widths):
        s.append(f'<rect x="{x:.0f}" y="69" width="12" height="12" rx="3" fill="{col}"/>')
        s.append(text(f"{x + 18:.0f}", 80, rl, 13, weight="600" if rl == routes[0][1] else None))
        x += w
    s.append(text(W / 2, 104, f"Watts, lower is better · hours on a full {wh:g} Wh battery", 13, INK, anchor="middle"))

    def bar_row(y, v, cap, col, rl, scale, first, digits=1):
        w = max(3, full * v / scale)
        s.append(f'<rect x="{left}" y="{y:.1f}" width="{w:.1f}" height="{bar}" rx="4" fill="{col}"/>')
        wt, hours = fmt(v, cap, digits)
        tx = left + w + 8
        s.append(text(f"{tx:.1f}", y + 11.5, wt, 13, INK, MONO, "600" if first else None, halo=True))
        tx += monow(wt, 13) + 8
        s.append(text(f"{tx:.1f}", y + 11.5, hours, 12, SOFT, MONO, halo=True))
        s.append(text(f"{tx + monow(hours, 12) + 10:.1f}", y + 11.5, rl, 11, SOFT, halo=True))

    def label(y, h, title, lines):
        ly = y + h / 2 - 4 - 7.5 * len(lines) + 7.5
        s.append(text(40, ly, title, 15, weight="600"))
        for j, ln in enumerate(lines):
            s.append(text(40, ly + 18 + 15 * j, ln, 12, MUTED))

    y = top
    for key, title, what in loads:
        group = len(routes) * pitch
        label(y, group, title, wrap(what, 12, left - 60))
        scale = max(watts.get(n, {}).get(key) or 0 for n, _, _ in routes)
        for i, (name, rl, col) in enumerate(routes):
            by = y + i * pitch + (pitch - bar) / 2
            v = watts.get(name, {}).get(key)
            if v is None:
                s.append(text(left, by + 11, f"– {rl}: " + missing.get(name, {}).get(key, "not measured"), 11, MUTED, MONO))
                continue
            bar_row(by, v, wh, col, rl, scale, name == routes[0][0])
        y += group + gap

    if rows:
        s.append(f'<line x1="40" y1="{round_top - 34}" x2="{W - 40}" y2="{round_top - 34}" stroke="{INK}" stroke-opacity="0.12"/>')
        s.append(text(40, round_top - 8, rnd["title"], 16, weight="600"))
        s.append(text(40 + textw(rnd["title"], 16) * 1.1 + 14, round_top - 8, rnd.get("subtitle", ""), 12, MUTED))
        scale = max(max(r["app"], r.get("macos") or 0) for r in rows)
        y = round_top + 20
        names = dict((k, l) for k, l, _ in POWER_LOADS)
        for r in rows:
            label(y, 2 * rpitch, names[r["load"]], [r["mac"]])
            bar_row(y + (rpitch - bar) / 2, r["app"], r["wh"], app_col, rapp, scale, True, 2)
            by = y + rpitch + (rpitch - bar) / 2
            if r.get("macos") is None:
                s.append(text(left, by + 11, "– macOS: " + r.get("macos_missing", "not measured"), 11, MUTED, MONO))
            else:
                bar_row(by, r["macos"], r["wh"], MACOS[2], "macOS", scale, False, 2)
            y += 2 * rpitch + rgap
    for i, line in enumerate(notes):
        s.append(text(W / 2, H - 14 - 16 * (len(notes) - 1 - i), line, 12, MUTED, anchor="middle"))
    s.append('</svg>')
    open(out, "w").write("\n".join(s) + "\n")


if __name__ == "__main__":
    main()
