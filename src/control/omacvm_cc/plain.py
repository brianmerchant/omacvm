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


def status(as_json: bool, fallback: bool = False) -> int:
    c = Controller()
    if not c.local.set_up:
        print("OmacVM is not set up in this VM: run omacvm apply on the Mac.", file=sys.stderr)
        return 1
    if not as_json and sys.stderr.isatty():
        print("asking the Mac and checking the VM ...", file=sys.stderr)
    c.refresh_mac()
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
    print("\n  Switch, repair, update: the control centre (omacvm), or on the Mac:")
    print("    omacvm enable FEATURE · omacvm disable FEATURE · omacvm update")
    if fallback:
        print("\n  The control centre needs Textual: sudo pacman -S python-textual")
    bad = [r for r in rows if r.status in (Status.FAILING, Status.NEEDS_PERSON)]
    return 1 if bad else 0
