"""What the VM knows by itself: its copy of OmacVM, its choices, its checks,
its logs, and the last answers from the Mac (a cache, so the first frame is
drawn from local files only)."""
from __future__ import annotations

import json
import os
import socket
import subprocess
import time

from . import state as S

# Where things are (the environment variables are for tests).
def share() -> str:
    return os.environ.get("OMACVM_SHARE", "/usr/local/share/omacvm")


def env_file() -> str:
    return os.environ.get("OMACVM_ENV", "/etc/omacvm/env")


def installed_file() -> str:
    return os.environ.get("OMACVM_INSTALLED", "/etc/omacvm/installed.json")


def check_socket() -> str:
    return os.environ.get("OMACVM_CHECK_SOCKET", "/run/omacvm/check.sock")


def cache_file() -> str:
    return os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "omacvm", "state.json")

# The services whose log the details screen shows, per feature: (scope, unit).
LOGS = {
    "bridge": [("user", "omacvm-bridge-events.service"), ("user", "omacvm-bridge-osd.service")],
    "wallpaper": [("user", "omacvm-wallpaper.service")],
    "gestures": [("system", "omacvm-gestures.service")],
    "scroll-momentum": [("system", "omacvm-gestures.service")],
    "omanotch": [("user", "notchcast.service")],
    "camera": [("user", "omacvm-camera.service")],
    "battery": [("system", "omacvm-battery.service")],
    "control-centre": [("system", "omacvm-check@*.service")],
    "graphics": [("system", "omacvm-venus-driver.service")],
}


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def read_json(path: str) -> dict:
    try:
        v = json.loads(read(path) or "{}")
        return v if isinstance(v, dict) else {}
    except ValueError:
        return {}


class Local:
    def __init__(self) -> None:
        self.features = S.parse_features_tsv(read(os.path.join(share(), "features.tsv")))
        self.version = read(os.path.join(share(), "VERSION")).strip() or "?"
        self.env = S.parse_env(read(env_file()))
        self.on = S.desired(self.features, self.env)
        self.vm_type = self.env.get("OMACVM_VM_TYPE", "")
        self.installed = read_json(installed_file())
        self.cache = read_json(cache_file())

    @property
    def set_up(self) -> bool:
        return bool(self.env)

    def save_cache(self, **kw) -> None:
        self.cache.update(kw)
        self.cache["saved_at"] = time.time()
        path = cache_file()
        try:
            os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.cache, f)
            os.replace(tmp, path)
        except OSError:
            pass   # a cache only

    def installed_parts(self) -> dict:
        p = self.installed.get("parts")
        return p if isinstance(p, dict) else {}


def write_attention(problems: int, updates: int) -> None:
    """~/.cache/omacvm/attention.json, which the bar item watches."""
    path = os.path.join(os.path.dirname(cache_file()), "attention.json")
    new = json.dumps({"problems": problems, "updates": updates})
    if read(path) == new:
        return
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path + ".tmp", "w", encoding="utf-8") as f:
            f.write(new)
        os.replace(path + ".tmp", path)
    except OSError:
        pass


def guest_checks(timeout: float = 90.0) -> list[S.Check] | None:
    """guest/check.sh --tsv, run as root by omacvm-check.socket (a fixed
    command; nothing is sent to it). None: the socket is not there."""
    path = check_socket()
    if not os.path.exists(path):
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        try:
            s.shutdown(socket.SHUT_WR)   # nothing to send
        except OSError:
            pass                         # it answered and closed already
        chunks = []
        while True:
            b = s.recv(65536)
            if not b:
                break
            chunks.append(b)
            if sum(map(len, chunks)) > 1 << 20:
                break
    except OSError:
        return None
    finally:
        s.close()
    return S.parse_check_tsv(b"".join(chunks).decode("utf-8", "replace"), "vm")


def log_tail(feature: str, lines: int = 12) -> list[str]:
    out: list[str] = []
    for scope, unit in LOGS.get(feature, []):
        cmd = ["journalctl", "--no-pager", "-o", "short", "-n", str(lines), "-u", unit]
        if scope == "user":
            cmd.insert(1, "--user")
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            continue
        for line in r.stdout.splitlines():
            if line.startswith("-- No entries --"):
                continue
            # "Oct 05 10:02:11 host unit[pid]: text" -> "10:02:11 text": no host name on screen.
            parts = line.split(" ", 4)
            if len(parts) == 5 and ":" in parts[2]:
                text = parts[4].split(": ", 1)[-1]
                out.append(f"{parts[2]} {text}")
            else:
                out.append(line)
    return out[-lines:]
