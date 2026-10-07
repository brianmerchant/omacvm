"""What the control centre says once Touch ID is turned on (ADR 0041, 3.0.4):
ready at once, or the one restart a VM started by OmacVM.app 3.0.3 or older
needs (it had no Touch ID port), and each app that needs its own switch for
it (omacvm-touchid-apps, the same lines as the notice and omacvm check)."""
from __future__ import annotations

import os
import subprocess

APPS = "/usr/lib/omacvm/omacvm-touchid-apps"
READY = "Touch ID is ready: try sudo -v in a terminal."
RESTART = "Touch ID: on - restart the VM once to finish (shut it down, then start it again)."


def apps_off(path: str | None = None) -> list[str]:
    """"1Password: turn on ..." for each installed app whose own switch is
    off; [] without the script (an OmacVM from before it) or on any error."""
    path = path or APPS
    if not os.access(path, os.X_OK):
        return []
    try:
        r = subprocess.run([path], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for line in r.stdout.splitlines() if r.returncode == 0 else []:
        f = line.split("\t")
        if len(f) == 4 and f[1] == "off" and f[2] and f[3]:
            out.append(f"{f[2]}: {f[3]}.")
    return out


def text(next_start: bool, apps: list[str]) -> str:
    """The banner after "Touch ID on" worked."""
    return " ".join([RESTART if next_start else READY] + apps)
