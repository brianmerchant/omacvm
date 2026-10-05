"""The release manifest says what it is: "kind": "control-manifest" (one key
signs it and OmacVM.app's feed, "app-feed"; the Bridge refuses any other
kind, src/bridge/mac/tests/control_tests.swift)."""
import json
import os
import subprocess
import sys

SRC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_build_writes_the_kind():
    out = subprocess.run([sys.executable, os.path.join(SRC, "release", "manifest.py"), "build", "--version", "2.9.1",
                          "--commit", "a" * 40, "--date", "2026-10-20", "--teams", "722686Y34B ABCDE12345"],
                         capture_output=True, text=True, check=True).stdout
    m = json.loads(out)
    assert m["schema"] == 1 and m["kind"] == "control-manifest" and m["version"] == "2.9.1"
    assert m["devid_teams"] == ["722686Y34B", "ABCDE12345"] and "next_spare_key" not in m
    assert "core" in m["parts"] and all(p["digest"].startswith("sha256:") for p in m["parts"].values())


def test_build_refuses_bad_teams():
    for teams in ("", "722686y34b", "SHORT", "A A"):
        r = subprocess.run([sys.executable, os.path.join(SRC, "release", "manifest.py"), "build", "--version", "2.9.1",
                            "--commit", "a" * 40, "--teams", teams], capture_output=True, text=True,
                           env=dict(os.environ, OMACVM_SIGN_ID="", PATH=os.environ.get("PATH", "")))
        assert r.returncode != 0, teams
