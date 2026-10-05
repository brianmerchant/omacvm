#!/usr/bin/env python3
"""Final-round results -> medians, a Markdown table and the chart's JSON.

  summarize.py results/*.jsonl [--json chart.json] [--include-preliminary]
               [--geekbench-scores scores.json | --fetch-geekbench] [--label TARGET=TEXT ...]

Reads the lines mac.sh, vm.sh and idle-power.sh wrote. Targets: mac, app,
app-rc2 (a second OmacVM.app build, e.g. a 3.0.0 RC with Vulkan), utm, fusion,
parallels; the app's rows are named after the build ("OmacVM 2.9.1"), or by
--label. Prints each test's
median per target and its share of the Mac. --json writes the input for
src/bench/chart.py --panel gpu.

Only clean lines go into the medians. Left out, and listed apart with the
reason: lines marked preliminary, taken on a busy Mac, while charging, on
battery, in Low Power Mode, not at thermal state nominal, after the energy
mode changed, in a guest narrower than 3000 px, or with Chrome's page other
than 1728x1080 at 2x; and page results that were unstable (CV >= 3 %), not
linear (half or double the work off by 10 %), fell back from the timer to
wall time, ran at another frame target than 40 ms (timer), or whose fixed
cost was 2 % of a frame or more (wall). --include-preliminary keeps the
lines (not the page results) for drafts; the JSON then says "preliminary".

The GPU throughput page has two methods (index.html). One method per row,
for every target: the GPU timer when every target has a validated one, else
wall time of long frames for all. A target's timer is valid when its score
is within -2 % and +10 % of its own wall-method score (the timer can't be
slower than the wall clock, and much faster means it misses work).

Geekbench prints only a link: the score comes from --geekbench-scores
({url: score}) or --fetch-geekbench (report.py's reader, a visible Chrome).
"""
import argparse, collections, importlib.util, json, os, re, statistics, sys

TARGETS = ["mac", "app", "app-rc2", "utm", "fusion", "parallels"]
NAMES = {"mac": "macOS", "app": "OmacVM.app", "app-rc2": "OmacVM.app RC", "utm": "UTM", "fusion": "VMware Fusion",
         "parallels": "Parallels"}
KEYS = [  # key, label, higher is better
    ("gpu-throughput", "GPU throughput, ray march (Gunits/s)", True),
    ("gpu-alu", "GPU ALU (GFLOPS, page)", True),
    ("gpu-fill", "GPU fill (Gpixels/s, page)", True),
    ("vkpeak-fp32", "vkpeak fp32 (GFLOPS)", True),
    ("vkpeak-fp16", "vkpeak fp16 (GFLOPS)", True),
    ("geekbench-gpu-opencl", "Geekbench 7 GPU, OpenCL", True),
    ("geekbench-gpu-vulkan", "Geekbench 7 GPU, Vulkan (macOS: Metal)", True),
    ("geekbench-gpu-metal", "Geekbench 7 GPU, Metal (macOS)", True),
    ("vkmark", "vkmark (VMs only)", True),
    ("glmark2", "glmark2 (VMs only)", True),
    ("basemark", "Basemark Web 3.0", True),
    ("aquarium", "WebGL Aquarium 30k (fps)", True),
    ("idle-power", "Idle power (W)", False),
]
BASE = {"geekbench-gpu-vulkan": "geekbench-gpu-metal"}   # the Mac has no Vulkan in Geekbench: Metal is its number
PAGE = {"throughput": "gpu-throughput", "alu": "gpu-alu", "fill": "gpu-fill"}
TIMER_TARGET_MS = 40
TIMER_OK = (0.98, 1.10)   # timer score / wall score
MIN_WIDTH = int(os.environ.get("FINAL_ROUND_MIN_GUEST_WIDTH", 3000))
VIEWPORT = os.environ.get("FINAL_ROUND_VIEWPORT", "1728x1080 at 2x")


def not_available(reason):
    """The reason a target has no number, as the chart prints it."""
    r = str(reason)
    if re.search(r"software renderer|swiftshader|llvmpipe", r, re.I) and "Vulkan" not in r:
        return "software renderer (check Chrome flags)"
    return r if r.lower().startswith(("not available", "no ")) else "not available: " + r


def line_problems(line, round_mode):
    """Why a whole line is left out (empty: it counts)."""
    why = []
    if line.get("preliminary"):
        why.append("preliminary" + (f" ({line['preliminary_why']})" if line.get("preliminary_why") else ""))
    if (line.get("quiet") or {}).get("busy"):
        why.append("busy Mac")
    ms = line.get("mac_state") or {}
    if ms.get("charging") not in (None, "No"):
        why.append("charging")
    if ms.get("external_power") not in (None, "Yes"):
        why.append("on battery")
    if ms.get("thermal") not in (None, "nominal"):
        why.append(f"thermal {ms['thermal']}")
    pm = ms.get("power_mode")
    if pm and re.search(r"\b(powermode|lowpowermode)=1\b", pm):
        why.append("Low Power Mode")
    if pm and round_mode and pm != round_mode:
        why.append(f"energy mode changed ({pm})")
    r = line.get("result") or {}
    widths = (r.get("vm") or {}).get("monitor_widths")
    if widths and min(widths) < MIN_WIDTH:
        why.append(f"guest {min(widths)} px wide")
    if line.get("test") == "browser" and "viewport" in r and r["viewport"] != VIEWPORT:
        why.append(f"Chrome page {r['viewport'] or 'unknown'}")
    return why


def page_method(r):
    m = r.get("method")
    if m:
        return m
    return "timer" if str(r.get("timer", "")).startswith("EXT_") else "wall"   # version 1 lines


def page_problems(r, t, method):
    """Why one page test's result is left out."""
    why = []
    if not t.get("stable", True):
        why.append(f"unstable (CV {t.get('cv')} %)")
    if not (t.get("scaling") or {}).get("linear", True):
        why.append("not linear at half or double the work")
    if t.get("timerFallbacks"):
        why.append("timer fell back to wall time")
    target = t.get("targetMs") or (r.get("options") or {}).get("targetMs")
    if method == "timer" and target and target != TIMER_TARGET_MS:
        why.append(f"target {target} ms, the round uses {TIMER_TARGET_MS}")
    if method == "wall" and t.get("syncOk") is False:
        why.append(f"fixed cost {round(100 * t.get('fixedShare', 0))} % of a frame")
    return why


def geekbench_key(test):
    return "geekbench-gpu-" + test.rsplit("-", 1)[-1].lower()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json")
    ap.add_argument("--include-preliminary", action="store_true")
    ap.add_argument("--geekbench-scores")
    ap.add_argument("--fetch-geekbench", action="store_true")
    ap.add_argument("--label", action="append", default=[], metavar="TARGET=TEXT",
                    help='name a target in the table and chart, e.g. app-rc2="OmacVM 3.0.0 RC2 · Vulkan"')
    a = ap.parse_args()

    lines = [json.loads(l) for f in a.files for l in open(f) if l.startswith("{")]
    # The round's energy mode: the Mac baseline's (else the first line's).
    modes = [l.get("mac_state", {}).get("power_mode") for l in sorted(lines, key=lambda l: l.get("target") != "mac")]
    round_mode = next((m for m in modes if m), None)

    # The app's rows name the build: "OmacVM 2.9.1", "OmacVM 3.0.0 RC2 · Vulkan".
    labels = {}
    for line in lines:
        hv = str((line.get("result") or {}).get("hypervisor") or "")
        m = re.match(r"OmacVM\.app (\S+)", hv)
        if line["target"] in ("app", "app-rc2") and m and m.group(1) != "unknown":
            labels[line["target"]] = "OmacVM " + m.group(1).replace("-rc", " RC").replace("-RC", " RC") + \
                (" · Vulkan" if line["target"] == "app-rc2" else "")
    for x in a.label:
        tg, _, lb = x.partition("=")
        if tg in TARGETS and lb:
            labels[tg] = lb
    for tg, lb in labels.items():
        NAMES[tg] = lb
    gb = {}
    if a.geekbench_scores:
        gb = json.load(open(a.geekbench_scores))
    elif a.fetch_geekbench:
        urls = sorted({l["result"]["url"] for l in lines if l["test"] == "geekbench" and l["result"].get("url")})
        here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "src", "bench", "report.py")
        spec = importlib.util.spec_from_file_location("report", here)
        rep = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rep)
        gb = {u: s[0] for u, s in rep.geekbench_scores(urls).items() if s}

    runs = collections.defaultdict(lambda: collections.defaultdict(list))   # target -> key -> values
    page = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))  # target -> method -> key
    missing = collections.defaultdict(dict)
    scene_s = set()   # glmark2's seconds per scene (one value in a fair round)
    excluded, prelim, versions = [], False, collections.defaultdict(lambda: collections.defaultdict(set))

    def drop(line, key, why, value=None):
        excluded.append({"target": line["target"], "test": key, "why": why, "value": value, "at": line.get("at")})

    for line in lines:
        t, r, tg = line["test"], line.get("result") or {}, line["target"]
        why = line_problems(line, round_mode)
        if why and a.include_preliminary:   # a draft: the line counts, the JSON says preliminary
            prelim, why = True, []
        if why:
            drop(line, t, "; ".join(why))
            continue
        for k, v in (("chrome", r.get("chrome") or r.get("browser") or (r.get("vm") or {}).get("chrome")),
                     ("glmark2", r.get("glmark2")), ("vkmark", r.get("vkmark")), ("vkpeak", r.get("version") if t == "vkpeak" else None)):
            if v:
                versions[k][tg].add(re.sub(r"^(Google Chrome|HeadlessChrome|Chrome)[ /]", "", str(v)).strip())
        if t == "gpu-throughput":
            if r.get("noTimer"):
                page[tg]["no-timer"]["all"].append(True)
                continue
            reason = r.get("notAvailable")
            if reason or not r.get("ok"):
                for key in PAGE.values():
                    missing[tg].setdefault(key, not_available(reason) if reason else "; ".join(r.get("errors", [])) or "failed")
                continue
            m = page_method(r)
            for name, key in PAGE.items():
                res = (r.get("tests") or {}).get(name)
                if not res:
                    continue
                pw = page_problems(r, res, m)
                if pw:
                    drop(line, f"{key} ({m})", "; ".join(pw), res.get("score"))
                else:
                    page[tg][m][key].append(res["score"])
        elif t == "vkpeak":
            reason = r.get("not_available") or r.get("error")
            for key, f in (("vkpeak-fp32", "fp32_gflops"), ("vkpeak-fp16", "fp16_gflops")):
                if r.get(f) is not None:
                    runs[tg][key].append(r[f])
                elif reason:
                    missing[tg][key] = not_available(reason)
        elif t == "geekbench":
            key = geekbench_key(r.get("test", ""))
            if key == "geekbench-gpu-vulkan" and tg == "mac":
                continue
            v = r.get("value") if isinstance(r.get("value"), (int, float)) else gb.get(r.get("url") or "")
            if v is not None:
                runs[tg][key].append(v)
            elif r.get("error"):
                missing[tg][key] = not_available(r["error"])
            elif r.get("url"):
                drop(line, key, f"Geekbench score not read ({r['url']}): --geekbench-scores or --fetch-geekbench")
        elif t in ("vkmark", "glmark2"):
            if t == "glmark2" and r.get("scene_seconds") is not None:
                scene_s.add(r["scene_seconds"])
            if r.get("value") is not None:
                runs[tg][t].append(r["value"])
            elif r.get("not_available") or r.get("error"):
                missing[tg][t] = not_available(r.get("not_available")) if r.get("not_available") else r["error"]
        elif t == "browser":
            if r.get("test") in ("aquarium", "basemark"):
                if r.get("value") is not None:
                    runs[tg][r["test"]].append(r["value"])
                else:
                    missing[tg].setdefault(r["test"], r.get("error") or "no result")
        elif t == "idle-power":
            if r.get("valid"):
                runs[tg]["idle-power"].append(r["watts_mean"])
            else:
                drop(line, "idle-power", "invalid window (charging, or no readings)")

    # The page: one method per row for every target.
    methods, validation = {}, collections.defaultdict(dict)
    for key in PAGE.values():
        tgs = [tg for tg in TARGETS if any(page[tg][m].get(key) for m in ("timer", "wall")) or page[tg]["no-timer"]]
        if not tgs:
            continue
        bad = []
        for tg in tgs:
            tm, wl = page[tg]["timer"].get(key), page[tg]["wall"].get(key)
            v = {"timer": statistics.median(tm) if tm else None, "wall": statistics.median(wl) if wl else None}
            if v["timer"] and v["wall"]:
                v["ratio"] = round(v["timer"] / v["wall"], 3)
                v["ok"] = TIMER_OK[0] <= v["ratio"] <= TIMER_OK[1]
            else:
                v["ok"] = False
            validation[tg][key] = v
            if not v["ok"]:
                bad.append(f"{NAMES[tg]}: " + ("no timer queries" if page[tg]["no-timer"] and not tm else
                                               "no clean timer run" if not tm else "no clean wall run" if not wl else
                                               f"timer/wall {v['ratio']}"))
        m = "timer" if not bad else "wall"
        methods[key] = {"method": m, "why": "every target has a validated GPU timer" if not bad else
                        "wall time of long frames for all; no valid timer: " + ", ".join(bad)}
        for tg in tgs:
            vals = page[tg][m].get(key)
            if vals:
                runs[tg][key] = vals
            else:
                missing[tg].setdefault(key, f"no clean {m}-method run")

    med = {tg: {k: round(statistics.median(v), 2) for k, v in ks.items() if v} for tg, ks in runs.items()}
    for tg in med:   # a number beats a "missing" from another run
        for k in med[tg]:
            missing.get(tg, {}).pop(k, None)
    known = {k for k, _, _ in KEYS}
    for e in excluded:   # a target whose every run was left out says so
        key = e["test"].split(" (")[0]
        if key in known and key not in med.get(e["target"], {}) and key not in missing.get(e["target"], {}):
            missing[e["target"]][key] = "left out: " + e["why"]
    missing = {tg: d for tg, d in missing.items() if d}

    warnings = []
    if len(scene_s) > 1:
        warnings.append("glmark2 scene lengths differ: " + ", ".join(f"{x:g} s" for x in sorted(scene_s)))
    for k, per in versions.items():
        seen = {v for vs in per.values() for v in vs}
        if len(seen) > 1:
            warnings.append(f"{k} versions differ: " + "; ".join(f"{NAMES[tg]} {', '.join(sorted(vs))}" for tg, vs in sorted(per.items())))

    targets = [tg for tg in TARGETS if tg in med or tg in missing]
    mac = med.get("mac", {})
    print("| | " + " | ".join(NAMES[tg] for tg in targets) + " |")
    print("|---" * (len(targets) + 1) + "|")
    for key, label, _ in KEYS:
        if key in methods:
            label += " · GPU timer" if methods[key]["method"] == "timer" else " · wall time, long frames"
        base = mac.get(BASE.get(key, key))
        cells = []
        for tg in targets:
            v = med.get(tg, {}).get(key)
            if v is None:
                cells.append(missing.get(tg, {}).get(key, "–"))
            elif tg != "mac" and base:
                cells.append(f"{v:g} ({round(100 * v / base)} %)")
            else:
                cells.append(f"{v:g}")
        if any(c != "–" for c in cells):
            print(f"| {label} | " + " | ".join(cells) + " |")
    for key, m in methods.items():
        print(f"\n{key}: {m['method']} ({m['why']})", end="")
    if methods:
        print()
    if excluded:
        print(f"\nLeft out of the medians ({len(excluded)}):")
        for e in excluded:
            print(f"- {NAMES.get(e['target'], e['target'])} {e['test']}" + (f" {e['value']:g}" if isinstance(e["value"], (int, float)) else "") + f": {e['why']}")
    for w in warnings:
        print(f"\nWARNING: {w}")
    if prelim:
        print("\nPRELIMINARY: lines from a busy or not agreed Mac are included (--include-preliminary).")
    if a.json:
        json.dump({"baseline": "mac", "preliminary": prelim, "labels": labels,
                   "glmark2_scene_seconds": scene_s.pop() if len(scene_s) == 1 else None, "medians": med, "missing": missing,
                   "runs": {tg: dict(ks) for tg, ks in runs.items()}, "methods": methods,
                   "validation": validation, "excluded": excluded, "warnings": warnings},
                  open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
