"""The battery agent (src/battery/guest/omacvm-battery) without a VM: the
Mac's snapshots in, the module's lines out (src/tests/battery.sh).
  agent-test.py AGENT              the checks below
  agent-test.py AGENT line VER     a snapshot on stdin -> its line for a
                                   module of version VER"""
import atexit
import importlib.machinery
import importlib.util
import json
import shutil
import sys
import tempfile
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("omacvm_battery", sys.argv[1])
spec = importlib.util.spec_from_loader("omacvm_battery", loader)
agent = importlib.util.module_from_spec(spec)
loader.exec_module(agent)

T = Path(tempfile.mkdtemp())
atexit.register(shutil.rmtree, T, True)
VERSION = T / "version"
agent.MODULE_VERSION = VERSION
agent.STATE_FILE = T / "state"

if sys.argv[2:3] == ["line"]:
    VERSION.write_text(sys.argv[3] + "\n")
    s = agent.decode(json.loads(sys.stdin.read()))
    sys.stdout.write(agent.state_line(s, agent.module_has_rate()).decode())
    sys.exit(0)

failed = False


def expect(what, ok):
    global failed
    print(("ok   " if ok else "FAIL ") + what)
    failed |= not ok


OLD_MAC = {"present": True, "percentage": 84, "state": "discharging", "acConnected": False,
           "timeToEmptySeconds": 54660, "timeToFullSeconds": None, "chargeLimit": None,
           "chargeNowMicroAh": 6818000, "chargeFullMicroAh": 8594000,
           "chargeFullDesignMicroAh": 8579000, "voltageMicroV": 12290000, "cycleCount": 98}
NEW_MAC = dict(OLD_MAC, currentMicroA=-573000, powerMicroW=7042170, somethingLater=1)
BASE = ("present=1 status=discharging capacity=84 ac=0 time_to_empty=54660 time_to_full=-1 "
        "charge_limit=-1 charge_now=6818000 charge_full=8594000 charge_full_design=8579000 "
        "voltage_now=12290000 cycle_count=98")


def line(snapshot, version):
    if version is None:
        VERSION.unlink(missing_ok=True)
    else:
        VERSION.write_text(version + "\n")
    return agent.state_line(agent.decode(snapshot), agent.module_has_rate()).decode()


expect("an older Mac (no current): the line as before, any module",
       line(OLD_MAC, "1.1.0") == BASE + "\n" and line(OLD_MAC, "1.0.0") == BASE + "\n")
expect("a newer Mac, module 1.1.0: current_now and power_now at the end",
       line(NEW_MAC, "1.1.0") == BASE + " current_now=-573000 power_now=7042170\n")
expect("a newer Mac, module 1.0.0: left out (it would refuse the whole line)",
       line(NEW_MAC, "1.0.0") == BASE + "\n")
expect("module 1.2.0 and 2.0: sent", "current_now=" in line(NEW_MAC, "1.2.0") and "power_now=" in line(NEW_MAC, "2.0"))
expect("no module version to read: left out", line(NEW_MAC, None) == BASE + "\n")
expect("a version that is no number: left out", line(NEW_MAC, "1.1-rc") == BASE + "\n")
expect("current 0 (full, on the charger) is sent as 0",
       line(dict(NEW_MAC, currentMicroA=0, powerMicroW=0), "1.1.0").endswith(" current_now=0 power_now=0\n"))
expect("a charging current above 0 stays above 0",
       " current_now=2100000 " in line(dict(NEW_MAC, state="charging", acConnected=True, currentMicroA=2100000), "1.1.0"))

bad = [("current past int32", dict(NEW_MAC, currentMicroA=-2147483648)),
       ("current a float", dict(NEW_MAC, currentMicroA=-573000.5)),
       ("current a string", dict(NEW_MAC, currentMicroA="-573000")),
       ("current true", dict(NEW_MAC, currentMicroA=True)),
       ("current null", dict(NEW_MAC, currentMicroA=None))]
for what, snap in bad:
    out = line(snap, "1.1.0")
    expect(f"{what}: no current_now, power_now still sent", "current_now" not in out and " power_now=7042170\n" in out)
for what, power in (("negative power", -1), ("power past int32", 2147483648), ("power a float", 7.5)):
    out = line(dict(NEW_MAC, powerMicroW=power), "1.1.0")
    expect(f"{what}: no power_now", "power_now" not in out and "current_now=-573000" in out)
out = line(dict(NEW_MAC, present=False, percentage=None, acConnected=True), "1.1.0")
expect("no battery: present=0 only", out == "present=0 ac=1\n")

# The feeder: writes on a change, and the Mac gone drops current and power.
VERSION.write_text("1.1.0\n")
feeder = agent.Feeder()
feeder.line(json.dumps(NEW_MAC).encode())
expect("feeder writes the new words", agent.STATE_FILE.read_text().endswith(" current_now=-573000 power_now=7042170\n"))
agent.STATE_FILE.write_text("untouched")
feeder.line(json.dumps(NEW_MAC).encode())
expect("the same snapshot again: no write", agent.STATE_FILE.read_text() == "untouched")
feeder.line(json.dumps(dict(NEW_MAC, currentMicroA=-600000, powerMicroW=7374000)).encode())
expect("only the current changed: written", " current_now=-600000 power_now=7374000\n" in agent.STATE_FILE.read_text())
feeder.gone()
gone = agent.STATE_FILE.read_text()
expect("the Mac gone: status unknown, no current_now/power_now",
       gone.startswith("present=1 status=unknown ") and "current_now" not in gone and "power_now" not in gone)

print("agent: FAILED" if failed else "agent: all passed")
sys.exit(1 if failed else 0)
