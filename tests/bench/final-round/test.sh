#!/bin/bash
# Offline tests of the final-round kit: no VM, no GPU, no Chrome.
#   tests/bench/final-round/test.sh
# - summarize.py: one timing method per row (timer only where every target
#   has a validated one), the lines and page results it leaves out, the
#   reasons it gives, Geekbench's Vulkan against the Mac's Metal
# - chart.py --panel gpu: the method in the headline row, glmark2 as scores,
#   Aquarium only when asked
# - common.sh: the preflight (charger, charging, Low Power Mode, thermal
#   state, energy mode, hypervisor services), the benchmark-VM names, which
#   VM runs
# - bench.sh: Geekbench GPU only on a GPU device, never PoCL or llvmpipe
# - the throughput page's script parses (node, where there is one)
set -uo pipefail
FR=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$FR/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# ---------- summarize.py and chart.py ----------
python3 - "$FR" "$R" "$T" <<'EOF' || fail=1
import json, os, subprocess, sys
FR, R, T = sys.argv[1:]
fail = False
def expect(what, cond, why=""):
    global fail
    print(("ok   " if cond else "FAIL ") + what + ("" if cond else f": {why}"))
    fail |= not cond

MAC = {"charging": "No", "external_power": "Yes", "thermal": "nominal", "power_mode": "powermode=0 lowpowermode="}
QUIET = {"busy": False}
def line(target, test, result, **kw):
    l = {"target": target, "test": test, "preliminary": False, "result": result,
         "mac_state": dict(MAC, **kw.pop("mac", {})), "quiet": dict(QUIET, **kw.pop("quiet", {})), "at": "t"}
    l.update(kw)
    return l
def page(method, score, chrome="Google Chrome 154.0.1", **test):
    t = {"score": score, "stable": True, "scaling": {"linear": True}, "targetMs": 40 if method == "timer" else 80}
    t.update(test)
    return {"ok": True, "method": method, "chrome": chrome, "tests": {"throughput": t}}
VM = {"monitor_widths": [3456], "chrome": "Google Chrome 154.0.1"}
def vm(r):
    r = dict(r); r["vm"] = VM; return r

def run(lines, *extra):
    f = os.path.join(T, "r.jsonl")
    with open(f, "w") as o:
        for l in lines:
            o.write(json.dumps(l) + "\n")
    out = os.path.join(T, "c.json")
    if os.path.exists(out):
        os.remove(out)
    p = subprocess.run([sys.executable, f"{FR}/summarize.py", f, "--json", out, *extra], capture_output=True, text=True)
    if p.returncode:
        print(p.stderr)
    return json.load(open(out)), p.stdout

# 1. Every target has a validated timer: the timer row.
base = [line("mac", "gpu-throughput", page("timer", 270)), line("mac", "gpu-throughput", page("wall", 268)),
        line("app", "gpu-throughput", vm(page("timer", 195))), line("app", "gpu-throughput", vm(page("wall", 180)))]
d, _ = run(base)
expect("all timers valid -> GPU timer row", d["methods"]["gpu-throughput"]["method"] == "timer", d["methods"])
expect("the timer row uses timer medians", d["medians"]["app"]["gpu-throughput"] == 195, d["medians"])

# 2. One VM without timer queries: wall time for every target, never mixed.
d, out = run(base + [line("utm", "gpu-throughput", vm({"ok": False, "noTimer": True, "notAvailable": "no GPU timer queries"})),
                     line("utm", "gpu-throughput", vm(page("wall", 90)))])
expect("a VM without timer -> wall row for all", d["methods"]["gpu-throughput"]["method"] == "wall", d["methods"])
expect("the wall row uses wall medians", d["medians"]["app"]["gpu-throughput"] == 180 and d["medians"]["mac"]["gpu-throughput"] == 268, d["medians"])
expect("the table names the method", "wall time, long frames" in out, out)

# 3. A timer far off its own wall time is not valid.
d, _ = run([line("mac", "gpu-throughput", page("timer", 270)), line("mac", "gpu-throughput", page("wall", 268)),
            line("app", "gpu-throughput", vm(page("timer", 240))), line("app", "gpu-throughput", vm(page("wall", 180)))])
expect("timer 33 % above wall -> wall row", d["methods"]["gpu-throughput"]["method"] == "wall", d["methods"])
expect("validation records the ratio", d["validation"]["app"]["gpu-throughput"]["ratio"] == 1.333, d["validation"])

# 4. What is left out of the medians.
bad_lines = [
    ("busy Mac", line("app", "vkpeak", vm({"fp32_gflops": 1}), quiet={"busy": True})),
    ("preliminary", line("app", "vkpeak", vm({"fp32_gflops": 2}), preliminary=True)),
    ("charging", line("app", "vkpeak", vm({"fp32_gflops": 3}), mac={"charging": "Yes"})),
    ("on battery", line("app", "vkpeak", vm({"fp32_gflops": 4}), mac={"external_power": "No"})),
    ("thermal fair", line("app", "vkpeak", vm({"fp32_gflops": 5}), mac={"thermal": "fair"})),
    ("Low Power Mode", line("app", "vkpeak", vm({"fp32_gflops": 6}), mac={"power_mode": "powermode=1 lowpowermode="})),
    ("energy mode changed", line("app", "vkpeak", vm({"fp32_gflops": 7}), mac={"power_mode": "powermode=2 lowpowermode="})),
    ("guest 2560 px wide", line("app", "vkpeak", dict(vm({"fp32_gflops": 8}), vm={"monitor_widths": [2560]}))),
    ("Chrome page 1280x800 at 2x", line("app", "browser", vm({"test": "basemark", "value": 9, "viewport": "1280x800 at 2x"}))),
    ("unstable", line("app", "gpu-throughput", vm(page("timer", 10, stable=False, cv=4)))),
    ("not linear", line("app", "gpu-throughput", vm(page("timer", 11, scaling={"linear": False})))),
    ("timer fell back", line("app", "gpu-throughput", vm(page("timer", 12, timerFallbacks=1)))),
    ("target 20 ms", line("app", "gpu-throughput", vm(page("timer", 13, targetMs=20)))),
    ("fixed cost", line("app", "gpu-throughput", vm(page("wall", 14, syncOk=False, fixedShare=0.05)))),
]
good = [line("mac", "vkpeak", {"fp32_gflops": 100}), line("app", "vkpeak", vm({"fp32_gflops": 99})),
        line("mac", "browser", {"test": "basemark", "value": 1000, "viewport": "1728x1080 at 2x"}),
        line("app", "browser", vm({"test": "basemark", "value": 800, "viewport": "1728x1080 at 2x"}))]
d, _ = run(base + good + [l for _, l in bad_lines])
whys = " | ".join(e["why"] for e in d["excluded"])
for name, _ in bad_lines:
    key = name.split()[0]
    expect(f"left out: {name}", key.lower() in whys.lower(), whys)
expect("medians only from clean lines (vkpeak)", d["medians"]["app"]["vkpeak-fp32"] == 99, d["medians"])
expect("medians only from clean lines (Basemark)", d["medians"]["app"]["basemark"] == 800, d["medians"])
expect("medians only from clean page results", d["medians"]["app"]["gpu-throughput"] == 195, d["medians"])
expect("clean JSON is not preliminary", d["preliminary"] is False)
d, _ = run(base + good + [bad_lines[0][1]], "--include-preliminary")
expect("--include-preliminary keeps a busy line, says preliminary", d["preliminary"] is True and d["medians"]["app"]["vkpeak-fp32"] == 50, d)

# 5. Reasons for a missing number.
d, _ = run(base + [line("fusion", "gpu-throughput", vm({"ok": False, "notAvailable": "software renderer (SwiftShader): not a GPU number"})),
                   line("fusion", "vkpeak", vm({"not_available": "no Vulkan device"})),
                   line("app", "vkpeak", vm({"not_available": "could not build vkpeak 20260527"}))])
expect("software renderer -> check Chrome flags", d["missing"]["fusion"]["gpu-throughput"] == "software renderer (check Chrome flags)", d["missing"])
expect("no Vulkan reason kept", d["missing"]["fusion"]["vkpeak-fp32"] == "no Vulkan device", d["missing"])
expect("the app's own reason kept", "could not build" in d["missing"]["app"]["vkpeak-fp32"], d["missing"])

# 6. Geekbench: scores by link, Vulkan in a VM against the Mac's Metal.
scores = os.path.join(T, "gb.json")
json.dump({"u/mac-metal": 200000, "u/mac-cl": 100000, "u/app-vk": 90000, "u/app-cl": 45000}, open(scores, "w"))
gb = [line("mac", "geekbench", {"test": "geekbench-gpu-Metal", "url": "u/mac-metal"}),
      line("mac", "geekbench", {"test": "geekbench-gpu-OpenCL", "url": "u/mac-cl"}),
      line("app", "geekbench", vm({"test": "geekbench-gpu-Vulkan", "url": "u/app-vk"})),
      line("app", "geekbench", vm({"test": "geekbench-gpu-OpenCL", "url": "u/app-cl"})),
      line("utm", "geekbench", vm({"test": "geekbench-gpu-OpenCL", "error": "not available: CPU OpenCL only (pocl CPU), no GPU"}))]
d, out = run(base + gb, "--geekbench-scores", scores)
expect("Geekbench scores read by link", d["medians"]["app"]["geekbench-gpu-opencl"] == 45000, d["medians"])
expect("Geekbench Vulkan is shared against Metal", "90000 (45 %)" in out, out)
expect("PoCL is 'not available', with the reason", "pocl" in d["missing"]["utm"]["geekbench-gpu-opencl"], d["missing"])
d, _ = run(base + gb)
expect("an unread Geekbench link is left out, not a zero", any("not read" in e["why"] for e in d["excluded"]), d["excluded"])

# 7. Different Chrome versions are flagged.
d, _ = run(base + [line("utm", "gpu-throughput", vm(page("wall", 90, chrome="Google Chrome 150.0.1")))])
expect("Chrome versions differ -> warning", any("chrome" in w for w in d["warnings"]), d["warnings"])

# 8. chart.py --panel gpu
d, _ = run(base + good + gb + [line("app", "glmark2", vm({"value": 455})), line("utm", "glmark2", vm({"value": 910})),
                              line("mac", "browser", {"test": "aquarium", "value": 100, "viewport": "1728x1080 at 2x"}),
                              line("utm", "vkpeak", vm({"not_available": "no Vulkan device"}))], "--geekbench-scores", scores)
chart = lambda *a: (subprocess.run([sys.executable, f"{R}/src/bench/chart.py", "--panel", "gpu", *a, os.path.join(T, "c.json"),
                                    os.path.join(T, "c.svg"), "test"], check=True), open(os.path.join(T, "c.svg")).read())[1]
svg = chart()
expect("chart: headline row names the method", "GPU time (timer query)" in svg, "")
expect("chart: glmark2 as scores, no macOS share", ">455<" in svg and "glmark2, no macOS version" in svg, "")
expect("chart: Geekbench Vulkan against Metal", "Vulkan (macOS: Metal)" in svg, "")
expect("chart: reason on a hatched bar", "UTM: no Vulkan device" in svg, "")
expect("chart: no Aquarium row unless asked", "Aquarium" not in svg, "")
expect("chart: Aquarium row with --aquarium", "Aquarium" in chart("--aquarium"), "")
sys.exit(1 if fail else 0)
EOF

# ---------- common.sh with stand-ins for macOS's tools ----------
S=$T/bin; mkdir -p "$S" "$T/home"
cat > "$S/swiftc" <<'EOF'
#!/bin/bash
# stand-in: the "built" binary prints what the test sets
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift 2 ;; *) src=$1; shift ;; esac; done
case $src in *thermal.swift) printf '#!/bin/bash\necho "${STUB_THERMAL:-nominal}"\n' ;; *) printf '#!/bin/bash\necho 0.5\n' ;; esac > "$out"
chmod +x "$out"
EOF
cat > "$S/ioreg" <<'EOF'
#!/bin/bash
echo "{\"ExternalConnected\" = ${STUB_EXT:-Yes},\"IsCharging\" = ${STUB_CHG:-No},\"CurrentCapacity\" = 100}"
EOF
cat > "$S/pmset" <<'EOF'
#!/bin/bash
case $* in *therm*) echo "Note: No thermal warning level has been recorded" ;; *) echo " powermode            ${STUB_PM:-0}" ;; esac
EOF
cat > "$S/ps" <<'EOF'
#!/bin/bash
case $* in *args=*) printf '%s\n' "${STUB_ARGS:-}" ;; *) printf '/sbin/launchd\n%s' "${STUB_PS:-}" ;; esac
EOF
cat > "$S/sysctl" <<'EOF'
#!/bin/bash
echo "{ 1.00 1.00 1.00 }"
EOF
chmod +x "$S"/*
C() {   # run bash code with common.sh loaded and the stand-ins first in PATH
  HOME=$T/home PATH="$S:$PATH" OUT=$T/round/out.jsonl bash -c ". '$FR/common.sh'; $1" 2>&1
}
mkdir -p "$T/round"
PRL=$'/Applications/Parallels Desktop.app/Contents/MacOS/Parallels Service.app/Contents/MacOS/prl_disp_service\n/Applications/Parallels Desktop.app/Contents/MacOS/prl_naptd'
OMQ=$'/Users/x/Applications/OmacVM.app/Contents/Resources/qemu/bin/qemu-system-aarch64'

check "busy: Parallels' service counts while testing UTM" \
  '[[ $(STUB_PS="$PRL" C "busy_check \"UTM\\.app/\"") == *"\"busy\":true"* ]]'
check "busy: Parallels' service is Parallels' own when testing it" \
  '[[ $(STUB_PS="$PRL" C "busy_check \"Parallels Desktop\\.app/|/prl_\"") == *"\"busy\":false"* ]]'
check "busy: Fusion's vmnet daemon counts for the Mac baseline" \
  '[[ $(STUB_PS="/Library/Application Support/VMware/vmnet-natd" C "busy_check") == *"\"busy\":true"* ]]'
check "busy: a second VM of the app under test counts" \
  '[[ $(STUB_PS="$OMQ"$'"'"'\n'"'"'"$OMQ" C "busy_check \"OmacVM[^/]*\\.app/\"") == *"\"target_vms\":2"* ]]'
check "busy: one VM of the app under test is quiet" \
  '[[ $(STUB_PS="$OMQ" C "busy_check \"OmacVM[^/]*\\.app/\"") == *"\"busy\":false"* ]]'

check "preflight: refuses without the charger" '! STUB_EXT=No C preflight >/dev/null'
check "preflight: refuses while charging" '! STUB_CHG=Yes C preflight >/dev/null'
check "preflight: refuses Low Power Mode" '! STUB_PM=1 C preflight >/dev/null'
check "preflight: refuses a thermal state other than nominal" '! STUB_THERMAL=fair C preflight >/dev/null'
check "preflight: passes on the agreed Mac and keeps the energy mode" 'C preflight >/dev/null && grep -q "powermode=0" "$T/round/round-state"'
check "preflight: refuses an energy mode change in the round" '! STUB_PM=2 C preflight >/dev/null'
check "preflight: FINAL_ROUND_ALLOW_BUSY=1 runs, marked preliminary" \
  '[[ $(STUB_PM=2 FINAL_ROUND_ALLOW_BUSY=1 C "preflight; echo \$PRELIM") == *true ]]'

for n in "Omarchy" "omarchy arm" "OmacVM Test" "Windows" "My VM" "Bench"; do
  check "bench VM name refused: $n" "! C 'bench_vm_ok \"$n\"' >/dev/null"
done
check "bench VM name accepted: Bench UTM" 'C "bench_vm_ok \"Bench UTM\""'
ARGS="$OMQ -name Bench OmacVM -machine virt -netdev user,id=n,hostfwd=tcp:127.0.0.1:52222-:22"
check "app: the named VM runs and the port is its SSH" 'STUB_ARGS="$ARGS" C "vm_running app \"Bench OmacVM\" 52222"'
check "app: another VM's port is refused" '! STUB_ARGS="$ARGS" C "vm_running app \"Bench OmacVM\" 52223" >/dev/null'
check "app: the user's VM is not the bench VM" '! STUB_ARGS="${ARGS/Bench OmacVM/OmacVM Test}" C "vm_running app \"Bench OmacVM\" 52222" >/dev/null'

# ---------- bench.sh: Geekbench GPU only on a GPU device ----------
cat > "$S/clinfo" <<'EOF'
#!/bin/bash
printf '  Device Name                                     %s\n  Device Type                                     %s\n' "$N1" "$T1"
[ -z "${N2:-}" ] || printf '  Device Name                                     %s\n  Device Type                                     %s\n' "$N2" "$T2"
EOF
chmod +x "$S/clinfo"
fn=$(sed -n '/^CPU_DEV=/,/^}/p' "$R/src/bench/bench.sh")
G() { PATH="$S:$PATH" N1=$1 T1=$2 N2=${3:-} T2=${4:-} bash -c "$fn"'; gpu_device OpenCL'; }
check "OpenCL on a GPU (rusticl) is used" 'G "zink Vulkan (Virtio-GPU Venus)" GPU >/dev/null'
check "PoCL alone is not a GPU" '[[ $(G "cpu-pocl-apple" CPU) == "CPU OpenCL only"* ]]'
check "PoCL next to the GPU: refused, it could be picked" '! G "zink (Venus)" GPU "cpu-pocl" CPU >/dev/null'

# ---------- the page's script parses ----------
if command -v node >/dev/null; then
  python3 -c 'import re,sys; print(re.search(r"<script>(.*)</script>", open(sys.argv[1]).read(), re.S).group(1))' \
    "$R/tests/bench/gpu-throughput/index.html" > "$T/page.js"
  check "throughput page script parses" 'node --check "$T/page.js"'
else
  echo "skip throughput page script (no node)"
fi
exit $fail
