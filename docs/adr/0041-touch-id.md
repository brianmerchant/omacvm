# 0041: Touch ID in the VM: the Mac answers yes or no to the VM's own PAM

Status: accepted (`touch-id`, for 3.0.2). Built for Parallels, UTM and
VMware Fusion; OmacVM.app's auth port is still to do (see Built, below).

## Context

In Omarchy, sudo, polkit prompts and 1Password's "Unlock using system
authentication" all ask for the Linux password. The Mac next to it has Touch
ID. The wish: touch the Mac's sensor instead of typing.

How the guest side asks today:

- sudo runs PAM service `sudo` (`auth include system-auth` on Arch).
- polkit runs PAM service `polkit-1` in `polkit-agent-helper-1` (a setuid
  helper, or a socket-started root service from polkit 126). Omarchy's
  polkit agent only shows the dialog; the helper does the PAM work.
- 1Password for Linux registers `com.1password.1Password.unlock` in
  `/usr/share/polkit-1/actions/com.1password.1Password.policy`
  (`allow_active` = `auth_self`, so polkit never caches the answer). The
  app asks polkit, polkit asks the agent, the helper runs `polkit-1`. So
  anything that answers in `polkit-1` also unlocks 1Password, and the
  1Password CLI and SSH agent prompts that use the same file. 1Password
  still wants its own password on its first unlock after it starts; that is
  1Password's rule, not ours.

How the Bridge knows a VM (ADR 0031): every VM has the shared Bridge token
and checks `/proof` first; requests under `/omacvm/` are also signed with
the VM's own key (HMAC, time, nonce, protocol header, body hash), and the
answer is signed back (`X-OmacVM-Answer`). The Bridge finds the VM from the
peer address in `omacvm vms --json` and the key on the Mac in
`omacvm/vm-keys/`. OmacVM.app's VMs go through the app's relay with the
relay key; the app names the VM. The control centre's key is in the
desktop user's home (`~/.config/omacvm-bridge/vm-key`), readable by every
program of that user.

## Options

PAM side:

1. A C PAM module (`pam_omacvm_touchid.so`). Full control over the
   conversation and timeouts, but a compiled module in every PAM stack,
   built for aarch64 in the VM, and a crash takes sudo with it.
2. `pam_exec.so` and a small client program. Stock PAM, nothing compiled
   into the stack; the client is a separate process, so a hang or crash is
   just "no". `pam_exec` has no timeout of its own and a bare environment,
   so the client sets its own `PATH` and timeouts.
3. `pam_fprintd` with a fake fingerprint reader. Wrong layer, no.

Key:

1. Reuse the control centre's `vm-key`. Any program of the desktop user
   could then sign Touch ID requests and put up Mac dialogs at will.
2. A separate Touch ID key, root only in the VM. Only PAM (root) can ask.

## Decision

pam_exec + client (option 2), a separate root-only key (option 2), one new
signed request on the Bridge, behind a new feature `touch-id`
(experimental, off by default, `mac,vm`, all routes the Bridge serves:
OmacVM.app, Parallels, UTM, VMware Fusion).

### Guest

- Client `/usr/lib/omacvm/omacvm-touchid` (bash + curl + openssl, as
  `omacvm-bridge`; runs as root).
- Key `/etc/omacvm/touchid-key` (root, 0600), made by `omacvm apply` when
  the feature goes on; the Mac keeps its copy as
  `omacvm/vm-keys/<vm>.touchid`. Off: both deleted, so a VM that kept its
  PAM lines gets 403 and falls to the password.
- PAM: one line at the top of `auth` in `/etc/pam.d/sudo` and
  `/etc/pam.d/polkit-1` only, before `auth include system-auth`:

  ```
  auth sufficient pam_exec.so quiet seteuid stdout /usr/lib/omacvm/omacvm-touchid
  ```

  `sufficient`: a yes ends auth; any failure is ignored and the password
  prompt follows as before. `seteuid`: without it the client runs with the
  caller's real uid and bash drops root. `stdout`: the client's one line
  shows as a PAM info message (in the terminal for sudo, in the agent's
  dialog for polkit).
  Never in `system-auth`, `login`, `sshd`, `su` or the lock screen
  (`hyprlock`). The lock screen may come later as its own switch.
- Only local sessions: the client asks only when the caller's logind
  session is on a local seat (`Remote=no`); over SSH it exits 1 at once.
  Someone logged in over SSH never puts a dialog on the Mac.
- What the request says (descriptive only; the guest can lie, and only
  about itself):
  - sudo: `kind: "sudo"`, the command from `/proc/<sudo pid>/cmdline`
    (sudo is setuid, the caller cannot change it after exec).
  - polkit: PAM has no action id. A polkit rule
    (`/etc/polkit-1/rules.d/49-omacvm-touchid.rules`) notes each checked
    action with `polkit.spawn` into `/run/omacvm-touchid/<uid>` (root,
    one line, time) and returns `NOT_HANDLED`, so polkit's own decision
    stays. The client uses the note when it is under 5 s old;
    `com.1password.1Password.*` becomes `kind: "1password"`, anything else
    `kind: "polkit"` with the action id. No fresh note: `kind: "polkit"`
    without an action. Two prompts within 5 s for one user can show the
    wrong label; the label never decides anything.
- Transport: Parallels, UTM, Fusion: TCP to the Bridge as today (`/proof`,
  token, then the signed request). OmacVM.app: a new virtio port
  `org.omacvm.auth`, root 0600 by udev rule, so the control centre's port
  (one opener, held up to 60 s by status requests) never blocks a sudo.
  The app relays it like `org.omacvm.control`.
- Timeouts in the client: 1 s to connect, 35 s for the answer, then exit 1.
  Ctrl+C in sudo kills the client; the closed connection cancels the Mac
  dialog.

### Request and answer

`POST /omacvm/touchid`, signed as in ADR 0031 but with the Touch ID key
and its own label (`"omacvm-touchid-request 1\n"` ...), so a control
centre signature never counts here and the other way round. Body, strict
JSON, at most 1 KB, unknown keys refused:

```json
{"kind": "sudo" | "polkit" | "1password", "user": "vincent",
 "detail": "pacman -Syu", "action": "org.freedesktop.systemd1.manage-units"}
```

`user` is `[a-z_][a-z0-9_-]{0,31}`; `detail` up to 200 bytes, `action` up
to 128 (`[A-Za-z0-9._-]`); the Mac strips control and bidi characters and
cuts `detail` to 80 characters for the dialog.

Answer, signed with `X-OmacVM-Answer` (nonce, status, body hash):

```json
{"result": "yes"}
{"result": "no", "reason": "cancelled" | "failed" | "timeout" | "busy"
   | "rate" | "locked" | "not-front" | "no-touch-id" | "lockout" | "off"}
```

The client exits 0 only on a 200 with `result: "yes"`, a valid answer
signature and its own nonce. Everything else, including an unsigned answer
or no answer, is exit 1 (password).

### Mac (Bridge, `touchid.swift`)

- Only VMs this Mac's OmacVM set up: the VM found as for `/omacvm/`
  (address or app relay) must have a Touch ID key on the Mac and the
  feature on. Unknown VM, no key, bad signature: 403, no dialog.
- Fast no, before any dialog: feature off (`off`), Mac screen locked or
  display asleep (`locked`), the VM's app (OmacVM.app, Parallels, UTM,
  Fusion) not the frontmost app (`not-front`), `canEvaluatePolicy` false:
  no sensor, no finger enrolled, lid closed without a Touch ID keyboard
  (`no-touch-id`), too many failed tries (`lockout`).
- The dialog: a fresh `LAContext` per request, never reused or kept
  (`touchIDAuthenticationAllowableReuseDuration` 0), invalidated at the
  end. Policy `.deviceOwnerAuthenticationWithBiometrics` with no fallback
  button (`localizedFallbackTitle = ""`). The Mac password as fallback
  only when the person turns on `touch_id_password_fallback` in the
  Bridge's `config.json` (then `.deviceOwnerAuthentication`).
- One dialog at a time on the Mac (`busy` for the next one). Per VM: one
  request every 2 s, 10 a minute; after 3 `cancelled`/`failed` in a row,
  60 s of `rate`. A dialog not answered in 30 s is invalidated
  (`timeout`); a client that disconnects invalidates it too.
- Nothing about the finger leaves the Mac: macOS gives the Bridge only
  success or an error code, and the VM only gets yes or no.
- Log: one line per request (VM, kind, result, never `detail`).

### Texts

macOS shows: "OmacVM Bridge is trying to <reason>. Touch ID to allow this."
So the reason starts with a verb:

| kind | reason |
|---|---|
| `1password` | `unlock 1Password in Omarchy` |
| `sudo` | `run sudo in Omarchy: <command>` |
| `polkit` with action | `allow "<action id>" in Omarchy` |
| `polkit` without | `allow a system request in Omarchy` |

With several VMs set up, " (<VM name>)" follows "Omarchy".
In the VM, the client's one line (PAM info):

- asking: `Touch ID on your Mac, or wait for the password prompt`
- fast no: `Touch ID not available (<why>), use your password`, why from
  the reason: `Mac locked`, `VM not in front`, `no Touch ID`, `too many
  tries`, `Touch ID off`. Silent for `cancelled`/`failed`/`timeout`; the
  password prompt is the message.

Control centre and CLI: the row "Touch ID" with "Unlock 1Password, sudo
and system prompts with the Mac's Touch ID. Your password keeps working."
`omacvm enable touch-id`, `omacvm disable touch-id`. `omacvm check`
reports: key on both sides, PAM lines present, the polkit rule, the port
(OmacVM.app), the last result.

## Consequences

- A yes protects only the VM's own boundary, the same as the VM password:
  it never unlocks anything on the Mac, and macOS asks again every time.
  Anyone who has root in the VM has the key and can ask for dialogs; a
  yes then gives them nothing they did not have.
- The desktop user's programs cannot ask directly (no key), but they can
  run `sudo` and so put up a dialog. That is the same as a password prompt
  they cause today; the dialog shows the command so the person can see
  what they allow. The "VM in front" rule keeps dialogs from appearing
  while the person does something else on the Mac.
- Another VM on the same network can answer in the Mac's place (ADR
  0031's impostor case), but cannot sign: the answer is a no.
- The password always works. Mac asleep: the VM is paused anyway; Mac
  locked, no sensor, Bridge not running, network down: the client says
  no within about a second and the password prompt comes.
- pam_faillock stays in `system-auth`, after our line: a Touch ID yes
  passes even while faillock locks the password. Accepted: faillock stops
  password guessing, and a Touch ID yes is not a guess.
- Tests: the Bridge's Touch ID decisions behind a protocol with a mocked
  `LAContext` (yes, no, error codes, timeout, disconnect, rate, busy); the
  client and PAM stack in a test VM against a mock Bridge (sudo,
  `pkexec true`, a polkit action standing in for 1Password; remote session
  refused; Bridge down falls to the password in under 2 s). One manual
  check with a real finger, by the person, on a Mac with Touch ID.

## Built

- Mac: `src/bridge/mac/touchid_policy.swift` (request, texts, limits, the
  order of the checks) and `touchid.swift` (LocalAuthentication, the Mac's
  state, the request). `control.swift` finds the VM and checks the
  signature (`touchIDCaller`); `requestMAC`, `answerMAC` and
  `verifyControlAuth` take the label.
- VM: `src/bridge/guest/omacvm-touchid` (the PAM client; Python, run with
  `-I`, not bash + curl + openssl: no key or token in any process's
  arguments, and the timeouts in one place), `touchid.sh on|off` (the PAM
  lines, the polkit rule `49-omacvm-touchid.rules`, `/run/omacvm-touchid`
  through tmpfiles, owned by `polkitd`), `guest/install.sh` and
  `omacvm check`. The polkit rule notes the action by user name (polkit
  gives rules no uid).
- Keys: `omacvm apply` makes `vm-keys/<vm>.touchid` (`touchid_key_ensure`)
  and puts it and the Bridge token in `/etc/omacvm` (root, 0600); off: the
  Mac's copy goes in apply, the VM's in `touchid.sh off`.
- The feature is on for a VM exactly when its Touch ID key is on the Mac:
  no key, 403 `off`, no dialog.
- Tests: `src/bridge/mac/tests/run.sh` (LAContext and the Mac's state
  mocked: request shapes, texts, every fast no, rate, pause after misses,
  busy, timeout, client gone, labels kept apart) and
  `src/tests/touchid-client.sh` (the client against a fake Bridge: yes, each
  no, unsigned, other key, other nonce, Bridge without the token, another
  PAM service, SSH, no key, polkit notes, Bridge down under 2 s; PAM lines
  in and out byte for byte). Both in CI.

Still to do:

- OmacVM.app: the `org.omacvm.auth` virtio port and its relay in the app.
  Until then the client says "Touch ID not available (OmacVM.app: not
  yet)" on the app's VMs and the password prompt comes.
- In a test VM (Parallels, UTM or Fusion): sudo, `pkexec true`, a polkit
  action standing in for 1Password, a remote session refused; real PAM and
  polkit, the Bridge with a mocked dialog.
- The manual check with a real finger (the person, on a Mac with Touch ID):
  `omacvm enable touch-id`, then in the VM `sudo true` (Touch ID dialog
  "run sudo in Omarchy: true", touch: no password), Cancel (the password
  prompt), the Mac locked or another app in front (password at once), and
  1Password's "Unlock using system authentication" after its first unlock.
