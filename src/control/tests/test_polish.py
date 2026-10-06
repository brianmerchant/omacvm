"""Polish after the control centre e2e (2026-10-06): local update time, the
report's help, its log excerpt without the check service's sudo noise, URL
logins redacted, installed.json part releases, the app VM's hang hint."""
import base64
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from omacvm_cc import collect, report as R  # noqa: E402
from omacvm_cc.controller import local_time  # noqa: E402

HERE = os.path.dirname(__file__)
SRC = os.path.abspath(os.path.join(HERE, "..", ".."))


def test_checked_time_is_local():
    env = dict(os.environ, TZ="Europe/Zurich")
    code = "import time, sys; time.tzset(); sys.path.insert(0, %r); from omacvm_cc.controller import local_time; " \
           "print(local_time('2026-10-05T20:56:00Z'))" % os.path.join(HERE, "..")
    out = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True, check=True).stdout
    assert out.strip() == "2026-10-05 22:56"
    assert local_time("") == "?" and local_time("junk") == "junk"


def test_report_help_prints_usage():
    r = subprocess.run([sys.executable, os.path.join(HERE, "..", "omacvm"), "report", "--help"],
                       capture_output=True, text=True, timeout=20)
    assert r.returncode == 0 and r.stdout.startswith("omacvm report [--print | --save FILE]")
    assert "collecting" not in r.stderr


def test_log_excerpt_drops_sudo_noise():
    lines = ["2026-10-05T22:00:01+0200 sudo[812]:    zorro : PWD=/ ; USER=root ; COMMAND=/usr/bin/true",
             "2026-10-05T22:00:01+0200 sudo[812]: pam_unix(sudo:session): session opened for user root(uid=0)",
             "2026-10-05T22:00:02+0200 omacvm-gestures[90]: planted line",
             "2026-10-05T22:00:03+0200 sudo[813]: pam_unix(sudo:session): session closed for user root"]
    assert collect.quiet(lines * 30, 40) == ["2026-10-05T22:00:02+0200 omacvm-gestures[90]: planted line"] * 30
    assert collect.quiet(["a b", "c d"], 1) == ["c d"]


def test_url_logins_are_redacted():
    text, counts = R.redact("git fetch https://zorro:hunter22@github.com/x/y.git and ssh://mara@10.0.0.1/z", R.Known())
    assert "zorro" not in text and "hunter22" not in text and "mara" not in text
    assert "https://<user>:<secret>@github.com/x/y.git" in text and "ssh://<user>@" in text
    plain, _ = R.redact("see https://github.com/gillesgoetsch/omacvm/issues", R.Known())
    assert "https://github.com/gillesgoetsch/omacvm/issues" in plain


def test_installed_parts_keep_their_own_release(tmp_path):
    tool = os.path.join(SRC, "release", "manifest.py")
    d = json.loads(subprocess.check_output([sys.executable, tool, "digests"]))
    a, b = sorted(d["parts"])[:2]
    m = {"kind": "control-manifest", "parts": {a: {"digest": d["parts"][a]["digest"], "release": "2.5.0"},
                                               b: {"digest": "sha256:00", "release": "2.6.0"}}}
    u = tmp_path / "updates.json"
    u.write_text(json.dumps({"raw": base64.b64encode(json.dumps(m).encode()).decode()}))
    e = json.loads(subprocess.check_output([sys.executable, tool, "digests", "--manifest", str(u)]))
    assert e["parts"][a]["release"] == "2.5.0"          # unchanged since that release
    assert e["parts"][b]["release"] == d["version"]     # changed: this copy's version
    e2 = json.loads(subprocess.check_output([sys.executable, tool, "digests", "--manifest", str(tmp_path / "none")]))
    assert all(p["release"] == d["version"] for p in e2["parts"].values())


def test_app_hang_hint_does_not_say_update():
    with open(os.path.join(HERE, "..", "omacvm_cc", "tui.py"), encoding="utf-8") as f:
        tui = f.read()
    with open(os.path.join(HERE, "..", "omacvm_cc", "bridge.py"), encoding="utf-8") as f:
        bridge = f.read()
    assert "(update OmacVM.app)" not in tui and "(update OmacVM.app)" not in bridge
