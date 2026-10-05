"""The omacvm entry in the VM: opened from the menu, the bar or the launcher
(--window), the plain-text table waits for Return when the control centre
cannot start (no Textual), instead of a window that closes at once."""
import os
import pty
import select
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(__file__))

from fakes import FakeChecks, FakeMac, vm_env  # noqa: E402

HERE = os.path.dirname(__file__)
ENTRY = os.path.join(HERE, "..", "omacvm")


def run_in_pty(args, env, send=b"", wait=8.0):
    m, s = pty.openpty()
    p = subprocess.Popen([sys.executable, ENTRY] + args, stdin=s, stdout=s, stderr=s, env=env, close_fds=True)
    os.close(s)
    out, end, sent = b"", time.monotonic() + wait, False
    while time.monotonic() < end:
        r, _, _ = select.select([m], [], [], 0.2)
        if r:
            try:
                out += os.read(m, 65536)
            except OSError:
                break
        if b"Press Return to close." in out and send and not sent:
            os.write(m, send)
            sent = True
        if p.poll() is not None and not r:
            break
    alive = p.poll() is None
    if alive:
        p.kill()
    os.close(m)
    return out.decode("utf-8", "replace"), alive


def no_textual_env(tmp_path, mac, checks):
    stub = tmp_path / "stub"
    (stub / "textual").mkdir(parents=True)
    (stub / "textual" / "__init__.py").write_text("raise ImportError('no textual here')\n")
    env = dict(os.environ, **vm_env(str(tmp_path), mac.port, checks.path))
    env["PYTHONPATH"] = str(stub)
    env["TERM"] = "xterm"
    return env


def test_window_waits_for_return(tmp_path):
    mac, checks = FakeMac(), FakeChecks()
    try:
        env = no_textual_env(tmp_path, mac, checks)
        out, alive = run_in_pty(["--window"], env, wait=6.0)
        assert "Press Return to close." in out and alive, out
        out, alive = run_in_pty(["--window"], env, send=b"\n", wait=8.0)
        assert "Press Return to close." in out and not alive, out
        assert "Trackpad gestures" in out
    finally:
        mac.stop()
        checks.stop()


def test_terminal_does_not_wait(tmp_path):
    mac, checks = FakeMac(), FakeChecks()
    try:
        out, alive = run_in_pty([], no_textual_env(tmp_path, mac, checks), wait=8.0)
        assert not alive and "Press Return" not in out and "python-textual" in out, out
    finally:
        mac.stop()
        checks.stop()
