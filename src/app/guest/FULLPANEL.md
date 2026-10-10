# FullPanel guest integration

FullPanel is OmacVM.app's **Full screen mode**, not a feature switch. CLI
setup offers **Native** (the default) and **Full Panel (Experimental)** after
the app route is chosen. An existing selection is the default on later runs.
Noninteractive setup takes `--fullscreen-mode native|fullpanel`; plans report
`fullscreen_mode` and include the option in their generated command.

`omacvm fullscreen native|fullpanel` changes the same app-wide setting later;
`omacvm fullscreen --configure` offers the choice interactively. It also
appears in the CLI's main menu. `--json` reads it without starting a VM.
These commands read/write `fullScreenMode` in the existing `org.omacvm.app`
UserDefaults domain (`fullPanel` is the app's stored value). The existing
graphical picker uses that exact key and refreshes when the app becomes
active. No VM feature, guest enable flag or second preference was added.
Updates do not change the selection. Other VM routes are unchanged.

FullPanel uses `omacvm.fullpanel.bar`, built from the installed stock Omarchy
bar. Only that owned copy receives the existing v4 Quickbar transform. Its
layout, redistribution, spacing and notch calculations are unchanged.

`guest/install.sh` already calls `app/guest/install.sh` for OmacVM.app guests.
That installer now calls `fullpanel-install.sh`, which installs the inactive
plugin and adds `hypr.omacvm_fullpanel` to the user's existing config. New
builds and the supported apply/update workflow use the same path, regardless
of the chosen mode. Installation never selects a bar or changes Omanotch
enablement. There is no new service,
timer, polling loop or shell process.

An incomplete/failed install leaves the owned
`~/.local/state/omacvm/fullpanel-install-failed` marker. Success clears it.
Failures return nonzero through guest install, apply, build and update; the
existing apply transaction mechanism can roll back its guest payload. Native
bar selection and contents are preserved. FullPanel activation refuses an
incomplete install; a previously working FullPanel session can keep its last
validated plugin, but health checks report the failed update until repaired.

During Hyprland config loading, the hook synchronously runs `omacvm-fullpanel
prepare`, before Omarchy's `hyprland.start` callback launches the shell. It
reads `/run/omacvm/host.env`, produced by the existing `omacvm-app-host` boot
service from the host's SMBIOS strings. `OMACVM_FULLPANEL=1` selects FullPanel;
an absent flag in an existing host.env selects native. A missing or invalid
host file preserves the current selection and reports an error.

On entry, the selector saves the original bar options and selection in
`~/.local/state/omacvm/fullpanel-native.json`. FullPanel's bar options live in
`~/.config/omacvm/fullpanel-bar.json`. Only the canonical shell.json's `bar`
subtree is switched; its unrelated settings and plugin list are preserved.
On native startup the original bar subtree returns. The original shell.json
bytes return too if nothing else changed. FullPanel preferences are retained
separately. A fresh guest without user shell.json carries its first-login
queued widget placements back into native mode.

FullPanel temporarily masks `notchcast.service` and the pending first-login
`omacvm-omanotch.service` with FullPanel-owned `/dev/null` links in
`$XDG_RUNTIME_DIR/systemd/user.control`, then reloads the manager, verifies
both units are masked, and stops them. This runtime control directory precedes
Omanotch's local unit in the [systemd user unit search path](https://github.com/systemd/systemd/blob/main/man/systemd.unit.xml).
Ordinary `systemctl mask --runtime` has lower priority than that local unit.
FullPanel does not edit original unit files, persistent enablement, drop-ins or Omanotch state.
Stop/start jobs are nonblocking because Omanotch's existing stop hooks can
call Hyprland IPC while config loading is in progress. Before selecting
FullPanel, the selector pins existing service PIDs, queues their stops,
signals the streamer's service cgroup with SIGKILL and waits up to two seconds for
the pinned processes using Linux pidfds. It then verifies no service main PID
or unmanaged notchcast process remains. This avoids waiting for stop hooks,
and avoids selecting a bar while an installer or streamer still runs. An
already running Omanotch installer causes the switch to be refused, with the
current bar preserved; its native file writes are never interrupted by FullPanel.
Each external command has a four-second timeout; the config-load lock is
nonblocking. There is no polling loop or indefinite startup wait.
Only masks created by FullPanel are undone. These masks also expire on reboot.
The dedicated bar excludes NOTCH outputs and contains no Omanotch parking or
notchbar IPC code. The existing Omanotch compositor configuration remains
loaded and unchanged; FullPanel does not create another display component.
Native startup commits the saved bar before removing masks or restarting
previously active services. The normal graphical session starts Omanotch
through its original enabled services. Disabled or externally masked units
retain their prior settings. The owned journal repairs an interrupted mask
transition on the next attempt. If unmasking fails, the valid native selection
is kept until suppression can safely be re-established; checks report it.

The dedicated manifest keeps `omarchy.clonedFrom: omarchy.bar`, as required
for Omarchy's [PluginRegistry aliases](https://github.com/omacom/omarchy-mac/blob/quattro/shell/services/PluginRegistry.qml)
and normal inherited bar functionality. It never inherits from the native
Omanotch/user clone. Omarchy loads exactly the bar selected by `bar.id`.

Plugins are staged and validated before publication. Unmanaged paths,
unsupported QML anchors, malformed config, missing native plugins and live
shell mode changes are rejected. Failed writes and service masking leave the
active config usable, with rollback of FullPanel-owned masks. Inactive
FullPanel plugins can update during a native session; an active plugin stays
unchanged until the next session. A failed update
of an already selected, validated FullPanel plugin keeps that previous copy.
Errors appear on stderr in the install output or compositor log. The shell's
own built-in bar fallback remains available for QML load failures.

`omacvm check` verifies installed components, the startup hook, installation
failure marker, the actual boot mode, the selected bar, the native recovery
record and service/process suppression. In a running shell it checks
`listPlugins`' active bar too, so a QML fallback is a failure. Native mode
continues all existing Omanotch streaming/parking checks. FullPanel mode
skips those intentional absences and expects the app's Omanotch link to be
closed; incorrect suppression is reported by the mode check. The guest boot
signal, rather than the next-start preference, drives these checks.

The legacy one-argument `fullpanel-bar.py:patch_text` import used by Omanotch
is now inert. Omanotch's installer, patcher, services, Lua, background and
display plugins have not been edited. Already patched native/user clones are
left as they are; this integration does not repair prior modifications.

Limits and acceptance test:

- The existing host mode signal is fixed at VM boot. Change the setting while
  the VM is stopped, then start it; there is no live mode switching watcher.
- Existing guests must receive this code through a supported OmacVM update
  once. Selecting a setting cannot bootstrap code into a guest that has never
  received it. This worktree has not been packaged or deployed.
- Tests use local fixtures and mocked guest commands. They do not verify QML
  rendering, real user-manager ordering, or physical Mac fullscreen behavior.
- Linux service transitions require pidfd support when a conflicting process
  is already running; otherwise switching is refused with the bar preserved.
- Unsupported stock bar anchors or unknown runtime overrides are reported,
  not overwritten. Existing native clones previously patched by experiments
  are preserved; this integration does not repair them.
- If Omanotch's installer is in progress when configuration loads, let it
  finish and start the next session. A normal boot masks the queued installer
  before the graphical session can start it.

For maintainer testing, first apply this worktree's guest code using
`./omacvm apply --no-mac --vm "<fresh VM name>"` while the fresh guest runs
in Native. Run `./omacvm check --vm "<fresh VM name>" --json`. Shut the guest
down, run `./omacvm fullscreen fullpanel` (or use the existing app picker),
and start it. Verify one Quickbar with the v4 layout and successful checks.
Shut down, select Native, start again, and verify the original Omanotch
experience and successful checks. Compare native plugin/config files before
and after. Repeat both starts and a supported apply once. This task did not execute
any of those VM steps or change the installed Mac application.
