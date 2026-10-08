"""`omacvm status` and the fallback when Textual is missing: the same
feature table as plain text, with the commands to use."""
from __future__ import annotations

import json
import sys

from . import look
from .controller import Controller
from .state import Status


def table(c: Controller, color: bool) -> str:
    rows = c.rows()
    codes = {"green": "32", "yellow": "33", "red": "31", "bright_black": "90", "cyan": "36"}
    out = []
    width = max((len(r.feature.title) for r in rows), default=10)
    for r in rows:
        mark = look.WORD[r.status] if look.ASCII else f"{look.glyph(r.status)} {look.WORD[r.status]}"
        pad = " " * max(2, 19 - len(mark))   # a glyph is one column
        if color:
            mark = f"\033[{codes[look.COLOR[r.status]]}m{mark}\033[0m"
        up = f"  {look.UPDATE} update" if r.update else ""
        out.append(f"  {mark}{pad}{r.feature.title:<{width}}  {r.note}{up}".rstrip())
    return "\n".join(out)


def status(as_json: bool, fallback: bool = False, why: str = "") -> int:
    c = Controller()
    if not c.local.set_up:
        print("OmacVM is not set up in this VM: run omacvm apply on the Mac.", file=sys.stderr)
        return 1
    if not as_json and sys.stderr.isatty():
        print("asking the Mac and checking the VM ...", file=sys.stderr)
    c.refresh_mac()
    c.refresh_gpu_memory()
    c.refresh_vm_checks()
    if c.linked:
        c.refresh_updates()
    rows = c.rows()
    if as_json:
        json.dump({"omacvm": c.local.version, "mac": c.hello.omacvm if c.hello else None,
                   "mac_problem": c.mac_problem() or None,
                   "features": [{"name": r.feature.name, "title": r.feature.title, "on": r.on, "status": r.status.value,
                                 "note": r.note, "update": r.update} for r in rows]}, sys.stdout, indent=1)
        print()
        return 0
    color = sys.stdout.isatty()
    mac = f"the Mac: OmacVM {c.hello.omacvm}" if c.hello else f"the Mac: {c.mac_problem()}"
    print(f"OmacVM {c.local.version} · {c.local.vm_type or '?'} · {mac}\n")
    print(table(c, color))
    if c.local.vm_type == "app":   # OmacVM.app alone has no omacvm command on the Mac
        print("\n  Switch, repair, update: the control centre (omacvm in a terminal, or the Omarchy menu).")
    else:
        print("\n  Switch, repair, update: the control centre (omacvm), or on the Mac:")
        print("    omacvm enable FEATURE · omacvm disable FEATURE · omacvm update")
    if fallback:
        print("\n  " + textual_fix(c, why=why))
    bad = [r for r in rows if r.status in (Status.FAILING, Status.NEEDS_PERSON)]
    return 1 if bad else 0


# A repair of the control centre restarts the Mac's Bridge when it builds it
# again: its job is asked about through that, as the control centre does
# (tui.LOST_AFTER), before it counts as lost.
LOST_AFTER = 120


def textual_ready() -> tuple[bool, str]:
    """Whether Textual loads now, in a new Python (OmacVM's copy in the VM
    may have just been replaced): (ok, why not)."""
    import os
    import subprocess
    control = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    code = ("import sys; sys.path.insert(0, sys.argv[1]); from omacvm_cc import vendor; why = vendor.use()\n"
            "try:\n import textual.app\nexcept Exception as e:\n sys.exit(why or f'{type(e).__name__}: {e}')")
    try:
        r = subprocess.run([sys.executable, "-c", code, control], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return False, str(e)
    return r.returncode == 0, (r.stderr.strip().splitlines() or [""])[-1]


def textual_fix(c: Controller, ask=input, wait: float = 1.0, why: str = "", ready=textual_ready) -> str:
    """Textual does not load (OmacVM's own copy, src/control/vendor): the Mac
    puts OmacVM into the VM again (a repair of the control centre, as r in
    the control centre does), never sudo in the VM. In a terminal it offers
    to start that now; the line says how it went, and the true reason when
    Textual still does not load."""
    import time
    from .bridge import BridgeError
    because = f" ({why})" if why else ""
    if not c.linked:
        return (f"The control centre could not load Textual{because}. Once the Mac answers, "
                "omacvm offers to repair it from there.")
    if not sys.stdin.isatty():
        return f"The control centre could not load Textual{because}: open omacvm in a terminal, it repairs it from the Mac."
    try:
        yes = ask(f"\n  The control centre could not load Textual{because}. "
                  "Repair it from the Mac now (OmacVM goes into this VM again)? [Y/n] ").strip().lower() in ("", "y", "yes")
    except EOFError:
        yes = False
    if not yes:
        return "The control centre needs Textual: omacvm asks again next time."
    try:
        job = c.start("reinstall", ["control-centre"])
    except Exception as e:   # BridgeError and friends: say it, nothing else to do here
        return f"The Mac could not install Textual: {e}"
    failures = 0
    while job.active:
        time.sleep(wait)
        try:
            job = c.poll(job.id)
            failures = 0
        except BridgeError:
            failures += 1   # the Bridge restarts when the repair builds it again: keep asking a while
            if failures > LOST_AFTER:
                return ("The Mac stopped answering about the repair (it may still finish there): "
                        "open omacvm again in a minute.")
    if job.state != "done":
        return (f"The Mac could not install Textual ({job.state}). "
                "Is the VM online? omacvm offers it again next time.")
    ok, still = ready()
    if ok:
        return "Textual is installed: open omacvm again for the control centre."
    return (f"The Mac's repair ran, but Textual still does not load: {still or 'no reason given'}. "
            "omacvm report sends what is needed to look into it.")
