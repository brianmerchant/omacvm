#!/bin/bash
# The benchmark chart and the pages that quote it say the same thing, and say
# it fairly. No VM, no Mac needed:
#   src/tests/bench-docs.sh
# - chart.py turns docs/benchmarks/chart.json into the committed SVG, byte for byte
# - a striped bar (a build that is not out, or not measured the same way) is
#   never longer than a released bar of another app in its group
# - the chart's alt texts in README.md and docs/compare.md give the app's
#   numbers the SVG gives
# - the power chart (docs/images/power.svg) is chart.py --panel power's output, its
#   hours are the battery over the watts, and README.md's alt text gives every
#   number in it
# - the GPU progress chart (docs/images/gpu-progress.svg) is chart.py --panel
#   progress's output, README.md's alt text gives every number in it, and the
#   medians are the ones docs/benchmarks/README.md's table gives
# - "not released yet" never names a release
# - the CHANGELOG names what build-kosmickrisp.sh needs
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$R" "$tmp" <<'EOF'
import json, re, subprocess, sys
R, tmp = sys.argv[1], sys.argv[2]
fail = False

def expect(what, ok, why=""):
    global fail
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f": {why}"))
    fail |= not ok

def read(p):
    return open(f"{R}/{p}", encoding="utf-8").read()

svg = read("docs/images/benchmarks.svg")
data = json.loads(read("docs/benchmarks/chart.json"))

# 1. The SVG is chart.py's output for chart.json (subtitle taken from the SVG).
sub = re.search(r'font-size="13" fill="#908caa" text-anchor="middle">([^<]*)</text>', svg)
out = f"{tmp}/chart.svg"
subprocess.run([sys.executable, f"{R}/src/bench/chart.py", f"{R}/docs/benchmarks/chart.json", out,
                sub.group(1) if sub else ""], check=True)
expect("chart.py gives the committed SVG", open(out, encoding="utf-8").read() == svg,
       "run src/bench/chart.py docs/benchmarks/chart.json docs/images/benchmarks.svg \"<subtitle>\"")

# 2. A striped bar never outranks a released one of another app.
med = data["medians"]
mac = med.get("mac", {})
for route, tests in data.get("unreleased", {}).items():
    for test in tests:
        v = med.get(route, {}).get(test)
        if v is None or not mac.get(test):
            continue
        beaten = [r for r in med if r not in ("mac", route) and test in med[r]
                  and test not in data.get("unreleased", {}).get(r, {}) and med[r][test] < v]
        top = [r for r in med if r not in ("mac", route) and test in med[r]
               and test not in data.get("unreleased", {}).get(r, {}) and med[r][test] >= v]
        expect(f"striped {route} {test} is not above a released bar",
               not (beaten and not top), f"{v} beats every released bar ({', '.join(beaten)})")

# 3. Alt texts give the app's numbers the SVG gives, group by group.
desc = re.search(r'<desc id="d">(.*?)</desc>', svg, re.S).group(1)
def app_values(text, prefix):
    vals = {}
    for m in re.finditer(r"\(([^()]*)\): ([^.]*(?:\.(?=\S)[^.]*)*)\.(?:\s|$)", text):
        bench, rest = m.group(1), m.group(2)
        first = re.sub(r"^" + re.escape(prefix), "", rest.split(",")[0].strip()).strip()
        n = re.match(r"(\d+)\b", first)
        vals[bench] = int(n.group(1)) if n else None
    return vals
want = app_values(desc, "OmacVM.app ")
for page in ("README.md", "docs/compare.md"):
    alt = re.search(r'<img src="[^"]*benchmarks\.svg" alt="([^"]*)"', read(page))
    got = app_values(alt.group(1) if alt else "", "OmacVM.app ")
    diff = {b: (want[b], got.get(b)) for b in want if got.get(b) != want[b]}
    expect(f"{page}: chart alt text matches the SVG for OmacVM.app", not diff,
           ", ".join(f"{b}: SVG {w}, alt {g}" for b, (w, g) in diff.items()))

# 3b. The power chart: chart.py's output, hours that follow from the watts, every number in README's alt text.
psvg = read("docs/images/power.svg")
sub = re.search(r'font-size="13" fill="#908caa" text-anchor="middle">([^<]*)</text>', psvg)
out = f"{tmp}/power.svg"
subprocess.run([sys.executable, f"{R}/src/bench/chart.py", "--panel", "power", f"{R}/docs/benchmarks/chart.json", out,
                sub.group(1) if sub else ""], check=True)
expect("chart.py --panel power gives the committed power SVG", open(out, encoding="utf-8").read() == psvg,
       "run src/bench/chart.py --panel power docs/benchmarks/chart.json docs/images/power.svg \"<subtitle>\"")
pw = data["power"]
gone = [f"{route} {load} {v} W" for route, loads in pw["watts"].items() for load, v in loads.items()
        if f"{v:.1f} W · {pw['battery_wh'] / v:.1f} h" not in re.sub(r"</text>\s*<text[^>]*>", " · ", psvg)]
for r in pw["round"]["rows"]:
    gone += [f"{r['mac']} {r['load']} {v} W" for v in (r["app"], r.get("macos"))
             if v is not None and f"{v:.2f} W · {r['wh'] / v:.1f} h" not in re.sub(r"</text>\s*<text[^>]*>", " · ", psvg)]
expect("power SVG shows every watt figure with its hours (battery over the draw)", not gone, ", ".join(gone))
expect("power: UTM idle is left out or marked", "idle" not in pw["watts"].get("utm", {}) or "#32" in psvg)
pdesc = re.search(r'<desc id="d">(.*?)</desc>', psvg, re.S).group(1)
pairs = re.compile(r"(\d+\.\d+) W \((\d+\.\d+) h\)")
want = pairs.findall(pdesc)
alt = re.search(r'<img src="[^"]*power\.svg" alt="([^"]*)"', read("README.md"))
got = pairs.findall(alt.group(1) if alt else "")
expect(f"README.md: power chart alt text gives the SVG's {len(want)} numbers in order", got == want and len(want) > 0,
       f"SVG {['/'.join(p) for p in want]}, alt {['/'.join(p) for p in got]}")
expect("README.md: the battery line links to the power chart",
       re.search(r"Optimized for battery\*\*<br>[^|]*\]\(#power-draw\)", read("README.md")) is not None
       and '<a name="power-draw"></a>' in read("README.md"))

# 3c. The GPU progress chart: chart.py's output, every number in README's alt text, medians as the docs give them.
gsvg = read("docs/images/gpu-progress.svg")
sub = re.search(r'font-size="13" fill="#908caa" text-anchor="middle">([^<]*)</text>', gsvg)
out = f"{tmp}/gpu-progress.svg"
subprocess.run([sys.executable, f"{R}/src/bench/chart.py", "--panel", "progress", f"{R}/docs/benchmarks/chart.json", out,
                sub.group(1) if sub else ""], check=True)
expect("chart.py --panel progress gives the committed GPU progress SVG", open(out, encoding="utf-8").read() == gsvg,
       "run src/bench/chart.py --panel progress docs/benchmarks/chart.json docs/images/gpu-progress.svg \"<subtitle>\"")
gdesc = re.search(r'<desc id="d">(.*?)</desc>', gsvg, re.S).group(1)
nums = re.compile(r"(\d+\.\d\dx) \(([\d,.]+(?: fps)?)\)|\b(\d[\d,.]*), the only version measured")
want = nums.findall(gdesc)
alt = re.search(r'<img src="[^"]*gpu-progress\.svg" alt="([^"]*)"', read("README.md"))
alt = alt.group(1) if alt else ""
got = nums.findall(alt.replace(" scores ", " "))
expect(f"README.md: GPU progress alt text gives the SVG's {len(want)} numbers in order", got == want and len(want) > 0,
       f"SVG {want}, alt {got}")
gp = data["gpu_progress"]
sys.path.insert(0, f"{R}/src/bench")
sys.dont_write_bytecode = True
import chart
section = read("docs/benchmarks/README.md").split("### GPU progress (2026-10-07)", 1)[-1].split("\n## ", 1)[0]
for t in gp["tests"]:
    for v, m, lo, hi, r, why in chart.progress_summary(t, gp["versions"])[0]:
        row = re.search(r"^\| " + re.escape(v) + r" \|.*$", section, re.M)
        if m is not None:
            runs = ", ".join(chart.progress_num(dict(t, unit=""), x) for x in t["runs"][v])
            cell = chart.progress_num(dict(t, unit=""), m) + (f" ({runs})" if len(t["runs"][v]) > 1 else "")
            expect(f"docs/benchmarks: GPU progress {t['key']} {v} reads {cell}", row is not None and f"| {cell} |" in row.group(0),
                   row.group(0) if row else "no row")

# 4. "Not released yet" with a version in brackets is a promise the release may not keep.
for page in ("README.md", "docs/compare.md", "docs/benchmarks/README.md"):
    bad = re.findall(r"not released yet \(\d+\.\d+[^)]*\)", read(page))
    expect(f"{page}: \"not released yet\" names no release", not bad, "; ".join(bad))

# 5. The CHANGELOG's KosmicKrisp line names what the build script refuses without.
kk = read("app/runtime/build-kosmickrisp.sh")
# The newest release section that has the line (an unreleased hotfix above it may not).
bullet = None
for section in read("CHANGELOG.md").split("\n## ")[1:]:
    bullet = re.search(r"\n- KosmicKrisp.*?(?=\n- |\n### |\Z)", section, re.S)
    if bullet:
        break
bullet = re.sub(r"\s+", " ", bullet.group(0)) if bullet else ""
for need, in_script in (("Xcode 26", "(Xcode 26)"), ("llvm", "brew install llvm)"),
                        ("spirv-llvm-translator", "brew install spirv-llvm-translator"),
                        ("spirv-tools", "brew install spirv-tools")):
    if in_script not in kk:
        expect(f"build-kosmickrisp.sh still needs {need}", False, "update this test and the CHANGELOG")
        continue
    named = re.search(r"(?<![-\w])" + re.escape(need) + r"(?![-\w])", bullet)
    expect(f"CHANGELOG's KosmicKrisp line names {need}", named, bullet[:120])

sys.exit(1 if fail else 0)
EOF
