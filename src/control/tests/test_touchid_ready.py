"""Turning Touch ID on from the control centre ends with what to do next
(3.0.4): "ready: try sudo -v", or the one restart a VM started by an older
OmacVM.app needs, and an app's own switch (omacvm-touchid-apps)."""
import asyncio
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))

import pytest  # noqa: E402

from omacvm_cc import touchid_ready as R  # noqa: E402

ONE_PASSWORD = "turn on Settings › Security › Unlock using system authentication to use Touch ID"


def fake_apps(tmp_path, out: str, rc: int = 0) -> str:
    p = tmp_path / "omacvm-touchid-apps"
    p.write_text(f"#!/bin/sh\nprintf '%s' '{out}'\nexit {rc}\n")
    p.chmod(0o755)
    return str(p)


def test_apps_off_lists_only_switches_that_are_off(tmp_path):
    p = fake_apps(tmp_path, f"1password\toff\t1Password\t{ONE_PASSWORD}\nbitwarden\ton\tBitwarden\tuses Touch ID\n")
    assert R.apps_off(p) == [f"1Password: {ONE_PASSWORD}."]


def test_apps_off_says_nothing_without_the_script_or_on_errors(tmp_path):
    assert R.apps_off(str(tmp_path / "none")) == []
    assert R.apps_off(fake_apps(tmp_path, "1password\toff\t1Password\tx\n", rc=1)) == []
    assert R.apps_off(fake_apps(tmp_path, "junk line\n\toff\t\t\n")) == []


def test_text():
    assert R.text(False, []) == "Touch ID is ready: try sudo -v in a terminal."
    assert R.text(True, []).startswith("Touch ID: on - restart the VM once to finish")
    assert R.text(False, ["1Password: x."]) == "Touch ID is ready: try sudo -v in a terminal. 1Password: x."


textual = pytest.importorskip("textual")
from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402


def run_touch_id_on(tmp_path, monkeypatch, extra: str = "") -> str:
    mac, checks = FakeMac(), FakeChecks()
    for k, v in vm_env(str(tmp_path), mac.port, checks.path, extra).items():
        monkeypatch.setenv(k, v)
    monkeypatch.setattr(R, "APPS", fake_apps(tmp_path, f"1password\toff\t1Password\t{ONE_PASSWORD}\n"))
    from omacvm_cc.controller import Controller
    from omacvm_cc.tui import ControlCentre
    from textual.widgets import DataTable

    async def go():
        a = ControlCentre(Controller())
        async with a.run_test(size=(110, 30)) as pilot:
            end = time.monotonic() + 8
            while not a.c.linked and time.monotonic() < end:
                await pilot.pause(0.05)
            names = [r.feature.name for r in a.rows]
            a.screen.query_one(DataTable).move_cursor(row=names.index("touch-id"))
            await pilot.press("space")
            end = time.monotonic() + 10
            while not a.last_result and time.monotonic() < end:
                await pilot.pause(0.05)
            posts = [b for m, p, b in mac.requests if p == "/omacvm/jobs"]
            assert posts and posts[-1] == {"action": "enable", "features": ["touch-id"]}
            return a.last_result
    try:
        return asyncio.run(go())
    finally:
        mac.stop()
        checks.stop()


def test_touch_id_on_says_ready_and_the_1password_switch(tmp_path, monkeypatch):
    r = run_touch_id_on(tmp_path, monkeypatch)
    assert r == f"Touch ID is ready: try sudo -v in a terminal. 1Password: {ONE_PASSWORD}."


def test_touch_id_on_in_a_vm_an_older_app_started_says_restart_once(tmp_path, monkeypatch):
    # OmacVM.app 3.0.3 or older started this VM without the Touch ID port.
    monkeypatch.setenv("OMACVM_AUTH_PORT", str(tmp_path / "no-port"))
    r = run_touch_id_on(tmp_path, monkeypatch, "OMACVM_VM_TYPE=app\n")
    assert r.startswith("Touch ID: on - restart the VM once to finish") and "1Password" in r


def test_touch_id_on_in_an_app_vm_with_the_port_is_ready(tmp_path, monkeypatch):
    (tmp_path / "port").write_text("")
    monkeypatch.setenv("OMACVM_AUTH_PORT", str(tmp_path / "port"))
    r = run_touch_id_on(tmp_path, monkeypatch, "OMACVM_VM_TYPE=app\n")
    assert r.startswith("Touch ID is ready")
