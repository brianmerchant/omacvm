# The person's path, end to end (release gate)

`cc-switches.sh` runs what a person does with OmacVM.app and its control
centre, on a real VM, and checks every answer. `src/release/release.sh` runs
it as a gate (step `e2e`): no release is published unless it passed for the
release commit, or an override with a reason is written down.

Why: on 2026-10-07 3.0.3 shipped with the fast network switch stranding a
running VM, the control centre's switches failing after an app update and
Touch ID refused on its first request after a Bridge restart. Every unit test
was green; nobody had pressed the switches in a real VM.

## What it does

| Step | What a person does | What is checked |
|---|---|---|
| prepare | Update VM in the app's window | the VM gets this app's OmacVM (`omacvm-version`, `logs/update.log`) |
| baseline | opens the control centre | it comes up "Mac linked", no row failing; `omacvm vms --json` reachable |
| switches | Space on every row, off and on (yes to questions) | the row's answer, `/etc/omacvm/env` and the VM folder's `features`, the Bridge's `job ... ended 0`, no refusal (409, unknown-vm) in its log, reachable |
| fastnet | Fast network on and off with the VM running, then each after a restart | the cc's answer, reachable, internet in the VM, `logs/network` (vmnet / user) |
| touchid | Touch ID on, restart, `sudo` (stand-in yes, then no), Bridge restarted then `sudo` at once, off | in without a password / the password prompt; the Bridge's log |
| graphics | Graphics: OpenGL, Vulkan (restart), Automatic | `omacvm graphics --json` agrees; this start is Vulkan |
| updates | U, c (check again) | no error; the Bridge's `update check: X (N parts)` |
| window | Check Now, the Fast network switch (Turn On…/Turn Off… before 3.0.5) in the app's window (VM stopped) | no error in the window; the VM's `fast-network` file |
| update | the release before installed, its Update VM, the features a new VM has, its control centre (`previous-*`); the app updates itself to this build (local feed, throwaway key); Update VM; every switch again | the app's version and signature, `update.log`, the switches as above |

The control centre is the real one: `omacvm` in tmux, started in the desktop
user's service manager (`systemd-run --user`) as a terminal on the desktop
is, so Touch ID's PAM client sees a local session. Keys go in with
`tmux send-keys`; answers are read from the terminal's screen
(`guest-cc.py`). The app's window is driven through Accessibility on the
launcher's own pid (`ax.swift`).

The Bridge takes at most 20 jobs an hour per VM (`jobsPerHour`); one pass
sends about 50. The count lives in the Bridge's memory, so the test starts
its test Bridge again before a step would go over it, and waits until the
control centre has asked the new one. Before the update, the test Bridge and
Gestures (they run from inside a test app; a person's live outside it) are
stopped, else the updater waits ("A VM runs from OmacVM Test").

Touch ID needs a finger and a Mac with Touch ID. The test identity's Bridge
(`org.omacvm.test.bridge`, never a release Bridge) reads a stand-in file,
`~/Library/Application Support/omacvm-test-bridge/touchid-test`: `yes` or
`no` answers instead of macOS's dialog (the log says "test stand-in"). The
rest of the path is the real one: the VM's PAM client, the app's relay, the
Bridge's checks and the signed answer.

## Results

`~/omacvm-e2e/<time>/`: `summary.tsv` (one line per step: ok, FAIL, BLOCKED,
skip), `result.json` (what the gate reads: the app's commit, `pass`), the
screens (`cc-N-*.json`), `run.log`. FAIL: the product is wrong. BLOCKED: this
Mac cannot run the step until a person does something once (below). Both
fail the gate; a skip says why the step does not apply here (Omanotch on a
Mac without a notch, or on a Mac with a notch but no test Omanotch on port
47911: the person's own is never used).

## The test Mac, once

- Apple Silicon, nobody working on it (it refuses with a battery unless
  `OMACVM_E2E_LAPTOP=1`, and when it was used in the last 5 minutes).
- The test identity, granted once (Accessibility, Input Monitoring for its
  Bridge and Gestures; Accessibility for the shell that runs the test, for
  the window steps).
- A test VM in the test app's VMs folder with autologin on, kept for this
  (`--clone-from KEPT --vm NAME` makes an APFS clone per run and deletes it
  after).
- The fast network's service for the test app: `src/net/mac/install.sh
  --app ~/Applications/"OmacVM Test.app"` once (an administrator's password);
  without it the fast network steps are BLOCKED.
- `OMACVM_SIGN_ID` (the Developer ID) for the update path. A test Mac whose
  SSH session cannot reach the Developer ID in its keychain (the Mac mini)
  gets the test app built and signed on the release Mac: `OMACVM_E2E_APP`
  for `remote.sh`, or `--app` with a copied build.
- Runs from a copy of the checkout, never one being edited (bash reads a
  script as it goes). `OMACVM_E2E_LOCKS`: the lock folders to hold, a colon
  list (default: the mini's VM lock and the test identity's).

## Run it

```bash
# a test identity build of the commit to test
OMACVM_SIGN_ID=<Developer ID> app/scripts/build-app.sh --test-identity
src/tests/e2e/cc-switches.sh --app app/dist/"OmacVM Test.app" \
  --clone-from "Bench OmacVM" --vm "OmacVM M-e2e" --previous latest
```

From the release Mac (release.sh step `e2e` does this when
`OMACVM_E2E_SSH` is set): `src/tests/e2e/remote.sh COMMIT OUT_DIR` with
`OMACVM_E2E_SSH="ssh -i KEY user@test-mac"` and
`OMACVM_E2E_ARGS='--clone-from "Bench OmacVM" --vm "OmacVM M-e2e" --previous latest'`.

`--only prepare,baseline,switches` (any list) runs part of it while working
on a fix; such a run never counts for the gate.

## Override

`OMACVM_RELEASE_E2E_OVERRIDE="<why, in a sentence>" src/release/release.sh X.Y.Z e2e`
lets the release go out without the gate. The reason, the time, M and who go
into the release output folder's `e2e-override.log`; publish and after say
it again.

## Stale frames after focus changes (`stale-frames/`)

`stale-frames/stale-frames.sh --vm NAME` checks #167 (window borders left
half drawn after a focus change) on a running test VM. Each round changes
the focus between two windows (Hyprland's dispatcher, a uinput tablet
crossing into the other window, or quick changes back and forth), waits for
the border animation, and takes the guest's scanout buffer (`scanout-read.c`:
TRANSFER_FROM_HOST of the plane's framebuffer, no frame asked for) and the VM
window on the Mac (ScreenCaptureKit, also on another Space). Then `grim
/dev/null` makes Hyprland draw the whole output again and both are taken
again. Any pixel below the bar that changed is a stale frame: in the guest's
buffer, or on the Mac. A grim screenshot cannot show this itself: Hyprland's
screencopy damages the whole output first. `src/tests/stale-frames-diff.sh`
tests the comparison offline (CI).
