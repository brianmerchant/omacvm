#!/bin/bash
# The benchmark chart and the pages that quote it say the same thing, and say
# it fairly. No VM, no Mac needed:
#   src/tests/bench-docs.sh
# - chart.py turns docs/benchmarks/chart.json into the committed SVG, byte for byte
# - a striped bar (a build that is not out, or not measured the same way) is
#   never longer than a released bar of another app in its group
# - the chart's alt texts in README.md and docs/compare.md give the app's
#   numbers the SVG gives
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

# 4. "Not released yet" with a version in brackets is a promise the release may not keep.
for page in ("README.md", "docs/compare.md", "docs/benchmarks/README.md"):
    bad = re.findall(r"not released yet \(\d+\.\d+[^)]*\)", read(page))
    expect(f"{page}: \"not released yet\" names no release", not bad, "; ".join(bad))

# 5. The CHANGELOG's KosmicKrisp line names what the build script refuses without.
kk = read("app/runtime/build-kosmickrisp.sh")
top = read("CHANGELOG.md").split("\n## ")[1]
bullet = re.search(r"\n- KosmicKrisp.*?(?=\n- |\n### |\Z)", top, re.S)
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
