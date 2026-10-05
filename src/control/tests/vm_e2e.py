#!/usr/bin/env python3
"""End-to-end driver for a test VM: runs the real control centre (Textual's
headless Pilot) as the desktop user, against the real Mac. Not a pytest file:
the Mac-side script of a test run calls it over SSH and checks the Mac too.

  vm_e2e.py first-frame            seconds to the first frame, and until the Mac and the checks answered
  vm_e2e.py toggle FEATURE         space on FEATURE's row (yes to a question), until the job ends
  vm_e2e.py repair FEATURE         r on FEATURE's row, until the job ends
  vm_e2e.py updates [check]        the update list (c first with "check"), and the silence switch state
  vm_e2e.py checks on|off          s on the updates screen until weekly checks are on or off
  vm_e2e.py install                u (install the update, yes to the question), until the job ends
                                   (no question and no job: "asked": false, "job_started": false);
                                   the banners shown while it ran
Prints one JSON object."""
import asyncio
import json
import os
import sys
import time

sys.path.insert(0, os.environ.get("OMACVM_CONTROL", "/usr/local/share/omacvm/control"))

from omacvm_cc.controller import Controller  # noqa: E402
from omacvm_cc.tui import ConfirmScreen, ControlCentre, FeaturesScreen, UpdatesScreen  # noqa: E402


async def settle(pilot, until, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        await pilot.pause(0.1)
        if until():
            return True
    return False


def row(app, name):
    return next(r for r in app.rows if r.feature.name == name)


async def main(argv):
    cmd = argv[0]
    out = {}
    t0 = time.monotonic()
    app = ControlCentre(Controller())
    async with app.run_test(size=(110, 32)) as pilot:
        await pilot.pause()
        out["first_frame_s"] = round(time.monotonic() - t0, 3)
        ok = await settle(pilot, lambda: (app.c.linked or app.c.mac_error) and app.c.vm_checks is not None, 120)
        out["ready_s"] = round(time.monotonic() - t0, 3)
        out["linked"] = app.c.linked
        out["mac_problem"] = app.c.mac_problem()
        out["ready"] = ok
        out["rows"] = {r.feature.name: [r.on, r.status.value, r.note, r.update] for r in app.rows}
        if cmd in ("toggle", "repair", "install"):
            name = argv[1] if cmd != "install" else app.rows[0].feature.name
            names = [r.feature.name for r in app.rows]
            from textual.widgets import DataTable
            app.screen.query_one(DataTable).move_cursor(row=names.index(name))
            await pilot.pause(0.1)
            out["before"] = [row(app, name).on, row(app, name).status.value]
            await pilot.press({"toggle": "space", "repair": "r", "install": "u"}[cmd])
            await pilot.pause(0.3)
            if isinstance(app.screen, ConfirmScreen):
                out["asked"] = True
                out["asked_text"] = app.screen.text
                await pilot.press("y")
            notes_seen = []
            orig = app.notify
            app.notify = lambda m, **kw: (notes_seen.append(str(m)), orig(m, **kw))
            started = await settle(pilot, lambda: bool(app.c.jobs), 20)
            out["job_started"] = started
            out["notices"] = notes_seen
            seen_busy, notes, banners = False, [], []

            def finished():
                nonlocal seen_busy
                b = app.banner()
                if b and (not banners or banners[-1] != b):
                    banners.append(b)
                for r in app.rows:
                    if r.status.value == "busy":
                        seen_busy = True
                        if not notes or notes[-1] != r.note:
                            notes.append(r.note)
                return app.c.jobs and not any(j.active for j in app.c.jobs.values())
            if started:
                await settle(pilot, finished, 1800)
            # The job's end refreshes the env, the checks and the Mac's view.
            await settle(pilot, lambda: not any(w.group == "job" and w.is_running for w in app.workers), 300)
            j = list(app.c.jobs.values())[-1] if app.c.jobs else None
            out["busy_shown"] = seen_busy
            out["busy_notes"] = notes
            out["banners_while_running"] = banners
            out["job"] = {"state": j.state, "text": j.text, "steps": j.step, "of": j.of, "failed_part": j.failed_part,
                          "failed_side": j.failed_side, "mac_omacvm": j.mac_omacvm, "lines": app.c.job_lines.get(j.id, [])[-12:]} if j else None
            out["banner"] = app.banner()
            out["result"] = app.last_result
            out["after"] = [row(app, name).on, row(app, name).status.value, row(app, name).note]
        elif cmd == "updates":
            if len(argv) > 1 and argv[1] == "check":
                await pilot.press("U")
                await pilot.pause(0.2)
                await pilot.press("c")
                await settle(pilot, lambda: not any(w.group == "updates" and w.is_running for w in app.workers), 60)
                await pilot.press("escape")
            out["updates"] = app.c.updates
            out["offered"] = app.c.update_offered()
            out["changed"] = [r.feature.name for r in app.rows if r.update]
        elif cmd == "checks":
            want = argv[1] == "on"
            await pilot.press("U")
            await pilot.pause(0.2)
            assert isinstance(app.screen, UpdatesScreen)
            for _ in range(2):
                if (app.c.updates or {}).get("checks_enabled", True) == want:
                    break
                await pilot.press("s")
                await settle(pilot, lambda: not any(w.group == "updates" and w.is_running for w in app.workers), 30)
            out["checks_enabled"] = (app.c.updates or {}).get("checks_enabled")
        if isinstance(app.screen, FeaturesScreen):
            await pilot.press("q")
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
