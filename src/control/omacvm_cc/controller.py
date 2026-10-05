"""The control centre's moving parts in one place, for the TUI and the plain
text output: local files, the Mac's answers, the VM's checks, jobs, updates.
Methods that talk to the Mac or run checks block: the TUI calls them from
worker threads."""
from __future__ import annotations

import dataclasses
import time

from . import state as S
from .bridge import Bridge, BridgeError, Hello
from .local import Local, guest_checks, write_attention

ACTION_FOR = {True: "enable", False: "disable"}
# With update checks off, an update is installed only from a check this recent
# (the Bridge has the same rule).
FRESH_SECONDS = 3600


def iso_age(stamp) -> float | None:
    """Seconds since an ISO time ("2026-10-05T10:41:00Z"), None if unknown."""
    if not isinstance(stamp, str) or not stamp:
        return None
    try:
        from datetime import datetime, timezone
        t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        age = time.time() - t.timestamp()
        return age if age > -60 else None   # a time in the future: unknown
    except ValueError:
        return None


class Controller:
    def __init__(self) -> None:
        self.local = Local()
        self.bridge = Bridge(self.local.env, self.local.version)
        self.hello: Hello | None = None
        self.mac_error: BridgeError | None = None
        c = self.local.cache
        self.mac_status: dict | None = c.get("mac_status") if isinstance(c.get("mac_status"), dict) else None
        self.vm_checks: list[S.Check] | None = None
        if isinstance(c.get("vm_checks"), str):
            self.vm_checks = S.parse_check_tsv(c["vm_checks"])
        self.checked_at: float | None = c.get("checked_at") if isinstance(c.get("checked_at"), (int, float)) else None
        self.from_cache = self.vm_checks is not None or self.mac_status is not None
        self.updates: dict | None = c.get("updates") if isinstance(c.get("updates"), dict) else None
        self.jobs: dict[str, S.Job] = {}
        self.job_lines: dict[str, list[str]] = {}

    # ---- the Mac ----
    @property
    def linked(self) -> bool:
        """The Mac answers and takes requests from this VM."""
        return self.hello is not None and self.mac_error is None

    def mac_looking(self) -> bool:
        """The Mac does not list this VM (yet), or its list has another VM at
        this address (it stopped, this one took its address): it is looking
        again, so ask again in a moment."""
        e = self.mac_error
        return e is not None and (e.code == "unknown-vm" or (e.looking and e.code in ("vm-key", "no-vm-key")))

    def mac_problem(self) -> str:
        """Why switching from here does not work right now ("" if it does)."""
        if self.mac_error is not None:
            return str(self.mac_error)
        if self.hello is None:
            return "still asking the Mac: a moment"
        return ""

    def refresh_mac(self) -> None:
        try:
            self.hello = self.bridge.hello()
            self.mac_error = None
        except BridgeError as e:
            self.hello, self.mac_error = None, e
            return
        try:
            st = self.bridge.status()
            if not st.get("pending"):
                self.mac_status = st
                self.local.save_cache(mac_status=st)
        except BridgeError as e:
            self.mac_error = e

    def refresh_updates(self, check: bool = False) -> dict | None:
        try:
            self.updates = self.bridge.check_updates() if check else self.bridge.updates()
            self.local.save_cache(updates=self.updates)
        except BridgeError as e:
            if check:
                raise
            self.mac_error = self.mac_error or e
        return self.updates

    def set_update_checks(self, on: bool) -> None:
        self.updates = self.bridge.set_update_checks(on)
        self.local.save_cache(updates=self.updates)

    # ---- the VM ----
    def refresh_vm_checks(self) -> None:
        checks = guest_checks()
        if checks is not None:
            self.vm_checks = checks
            self.checked_at = time.time()
            self.from_cache = False
            self.local.save_cache(vm_checks="\n".join(
                f"{c.status}\t{c.name}\t{c.detail}\t{'1' if c.human else ''}\t{c.feature}" for c in checks),
                checked_at=self.checked_at)

    def reload_local(self) -> None:
        """After a job: the VM's env and installed parts changed."""
        cache = self.local.cache
        self.local = Local()
        self.local.cache = cache
        self.bridge = Bridge(self.local.env, self.local.version)

    # ---- the model ----
    @property
    def checks_enabled(self) -> bool:
        """The Mac's update check setting (off: no update marks, no prompts)."""
        return (self.updates or {}).get("checks_enabled", True) is not False

    def manifest_fresh(self) -> bool:
        """The update information comes from a check in the last hour."""
        age = iso_age((self.updates or {}).get("checked_at"))
        return age is not None and age < FRESH_SECONDS

    def manifest(self) -> dict | None:
        m = (self.updates or {}).get("manifest")
        return m if isinstance(m, dict) else None

    def mac_version(self) -> str:
        return str((self.updates or {}).get("omacvm") or (self.hello.omacvm if self.hello else "") or "")

    def update_offered(self) -> bool:
        """The release is newer than this VM's OmacVM and not older than the
        Mac's: never a downgrade (a dev checkout, a Mac ahead of the release)."""
        m = self.manifest()
        return m is not None and S.update_offered(m.get("version"), self.local.version, self.mac_version())

    def offer(self) -> dict:
        """The release's parts, only when it is an update for this VM."""
        m = self.manifest()
        parts = m.get("parts") if m and self.update_offered() else None
        return parts if isinstance(parts, dict) else {}

    def rows(self, with_updates: bool | None = None) -> list[S.Row]:
        """The features. Update marks only while update checks are on (or
        with_updates=True: the Updates screen, the one place that shows an
        update when they are off)."""
        if with_updates is None:
            with_updates = self.checks_enabled
        avail = {}
        mac_checks = None
        if self.mac_status:
            for f in self.mac_status.get("features") or []:
                if isinstance(f, dict) and f.get("name"):
                    avail[f["name"]] = S.Avail(bool(f.get("available", True)), str(f.get("reason") or ""))
            if isinstance(self.mac_status.get("checks"), list):
                mac_checks = S.parse_mac_checks(self.mac_status["checks"])
        checks = None if self.vm_checks is None and mac_checks is None else (self.vm_checks or []) + (mac_checks or [])
        mac_features = set(self.hello.features) if self.hello and self.hello.features else None
        rows = S.build_rows(self.local.features, self.local.on, vm_type=self.local.vm_type, avail=avail,
                            checks=checks, jobs=list(self.jobs.values()), installed=self.local.installed_parts(),
                            offer=self.offer(), mac_features=mac_features, show_updates=with_updates)
        g = S.graphics_row(self.mac_status, self.local.vm_type, list(self.jobs.values()), checks)
        return rows + [g] if g is not None else rows

    def graphics(self) -> str:
        """This VM's Graphics setting as the Mac last said it ("" unknown)."""
        g = (self.mac_status or {}).get("graphics")
        return str(g.get("graphics") or "") if isinstance(g, dict) else ""

    # ---- jobs ----
    def _job(self, d: dict) -> S.Job:
        j = S.Job(id=str(d.get("id", "")), action=str(d.get("action", "")),
                  features=tuple(str(x) for x in d.get("features") or ()), state=str(d.get("state", "running")),
                  step=int(d.get("step") or 0), of=int(d.get("of") or 0), text=str(d.get("text", "")),
                  failed_part=str(d.get("failed_part") or ""), mac_omacvm=str(d.get("mac_omacvm") or ""),
                  failed_side=str(d.get("failed_side") or ""))
        self.jobs[j.id] = j
        self.job_lines[j.id] = [str(x) for x in d.get("lines") or []]
        return j

    def start(self, action: str, features: list[str] | tuple[str, ...] = ()) -> S.Job:
        return self._job(self.bridge.start_job(action, list(features)))

    def poll(self, job_id: str) -> S.Job:
        return self._job(self.bridge.job(job_id))

    def vm_name(self) -> str:
        """This VM's name in its app (from omacvm apply), "" if not known."""
        import base64
        try:
            return base64.b64decode(self.local.env.get("OMACVM_VM_NAME_B64", ""), validate=True).decode("utf-8")
        except ValueError:
            return ""

    def lose(self, job_id: str) -> S.Job:
        """The Mac stopped answering about a job: it ends here as failed (it
        may still finish on the Mac; the next status shows how it went)."""
        j = dataclasses.replace(self.jobs[job_id], state="failed", text="the Mac stopped answering about this job")
        self.jobs[job_id] = j
        return j

    def write_attention(self, rows: list[S.Row]) -> None:
        """For the bar item: how many features need a look, and updates."""
        problems = sum(1 for r in rows if r.status in (S.Status.FAILING, S.Status.NEEDS_PERSON))
        updates = sum(1 for r in rows if r.update) if self.checks_enabled else 0
        write_attention(problems, updates)

    def active_job(self) -> S.Job | None:
        return next((j for j in self.jobs.values() if j.active), None)
