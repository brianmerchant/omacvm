#!/usr/bin/env python3
"""Final-round results -> medians, a Markdown table and the chart's JSON.

  summarize.py results/*.jsonl [--json chart.json]

Reads the lines mac.sh, vm.sh and idle-power.sh wrote. Prints each test's
median per target and its share of the Mac. --json writes the input for
src/bench/chart.py --panel gpu ("medians", "missing", "runs"). A test that
reported "not available" goes to "missing" with its reason. Lines taken on a
busy Mac ("preliminary") are kept apart: if any line is preliminary, the JSON
says so and the table shows it.
"""
import json, statistics, sys

TARGETS = ["mac", "app", "utm", "fusion", "parallels"]
NAMES = {"mac": "macOS", "app": "OmacVM.app", "utm": "UTM", "fusion": "VMware Fusion", "parallels": "Parallels"}
KEYS = [  # chart key, label, higher is better
    ("gpu-throughput", "GPU throughput (Gunits/s)", True),
    ("gpu-alu", "GPU ALU (GFLOPS, page)", True),
    ("gpu-fill", "GPU fill (Gpixels/s, page)", True),
    ("vkpeak-fp32", "vkpeak fp32 (GFLOPS)", True),
    ("vkpeak-fp16", "vkpeak fp16 (GFLOPS)", True),
    ("basemark", "Basemark Web 3.0", True),
    ("aquarium", "WebGL Aquarium 30k (fps)", True),
    ("glmark2", "glmark2", True),
    ("idle-power", "Idle power (W)", False),
]


def values(line):
    """(key, value or None, reason) for one result line."""
    t, r = line["test"], line["result"]
    reason = r.get("notAvailable") or r.get("not_available") or r.get("error")
    if t == "gpu-throughput":
        if reason or not r.get("ok"):
            yield "gpu-throughput", None, reason or "; ".join(r.get("errors", [])) or "failed"
            return
        for name, key in (("throughput", "gpu-throughput"), ("alu", "gpu-alu"), ("fill", "gpu-fill")):
            if name in r.get("tests", {}):
                yield key, r["tests"][name]["score"], None
    elif t == "vkpeak":
        yield "vkpeak-fp32", r.get("fp32_gflops"), reason
        yield "vkpeak-fp16", r.get("fp16_gflops"), reason
    elif t == "browser":
        if r.get("test") in ("aquarium", "basemark"):
            yield r["test"], r.get("value"), r.get("error") or (None if r.get("value") is not None else "no result")
    elif t == "glmark2":
        yield "glmark2", r.get("value"), reason
    elif t == "idle-power":
        yield "idle-power", r.get("watts_mean") if r.get("valid") else None, None if r.get("valid") else "invalid window (charging, or no readings)"


def main():
    args = sys.argv[1:]
    out = None
    if "--json" in args:
        i = args.index("--json")
        out = args[i + 1]
        del args[i:i + 2]
    runs, missing, prelim = {}, {}, False
    for f in args:
        for l in open(f):
            if not l.startswith("{"):
                continue
            line = json.loads(l)
            prelim |= bool(line.get("preliminary"))
            for key, v, reason in values(line):
                if v is not None:
                    runs.setdefault(line["target"], {}).setdefault(key, []).append(v)
                elif reason:
                    missing.setdefault(line["target"], {})[key] = (
                        "not available (no Vulkan in the VM)" if "Vulkan" in reason or "vulkan" in reason else reason)
    med = {t: {k: round(statistics.median(v), 2) for k, v in ks.items()} for t, ks in runs.items()}
    for t in med:   # a number beats a "missing" from another run
        for k in med[t]:
            missing.get(t, {}).pop(k, None)
    targets = [t for t in TARGETS if t in med or t in missing]
    print("| | " + " | ".join(NAMES[t] for t in targets) + " |")
    print("|---" * (len(targets) + 1) + "|")
    mac = med.get("mac", {})
    for key, label, _ in KEYS:
        cells = []
        for t in targets:
            v = med.get(t, {}).get(key)
            if v is None:
                cells.append(missing.get(t, {}).get(key, "–"))
            elif t != "mac" and mac.get(key):
                cells.append(f"{v:g} ({round(100 * v / mac[key])} %)")
            else:
                cells.append(f"{v:g}")
        if any(c != "–" for c in cells):
            print(f"| {label} | " + " | ".join(cells) + " |")
    if prelim:
        print("\nPRELIMINARY: some lines were taken on a busy Mac.")
    if out:
        json.dump({"baseline": "mac", "preliminary": prelim, "medians": med, "missing": missing,
                   "runs": runs}, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()
