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
  polkit agent only shows the dialog; the helper does the PAM work. Arch's
  polkit 127 (checked in a VM): the socket-started helper, in a systemd
  sandbox without network (`PrivateNetwork=yes`,
  `RestrictAddressFamilies=AF_UNIX`), and its PAM file only in
  `/usr/lib/pam.d/polkit-1`.
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

- Client `/usr/lib/omacvm/omacvm-touchid` (Python, run with `-I`; runs as
  root; see Built for why not bash + curl + openssl).
- Key `/etc/omacvm/touchid-key` (root, 0600), made by `omacvm apply` when
  the feature goes on; the Mac keeps its copy as
  `omacvm/vm-keys/<vm>.touchid`. Off: both deleted, so a VM that kept its
  PAM lines gets 403 and falls to the password.
- PAM: one line at the top of `auth` in `/etc/pam.d/sudo`, `sudo-i` (where
  it exists) and `polkit-1` only, before `auth include system-auth`. A
  service with only the vendor's file (`/usr/lib/pam.d/polkit-1`) gets a
  copy in `/etc/pam.d` with the line; off removes the copy, so the vendor's
  file counts again:

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
- polkit's helper sandbox (polkit 127): a drop-in
  (`polkit-agent-helper@.service.d/omacvm-touchid.conf`) allows `AF_INET`
  with `IPAddressDeny=any` and `IPAddressAllow=<the Bridge's address>`, so
  the helper reaches the Mac's Bridge and nothing else. Without it the
  client cannot connect and polkit always asks for the password.
- Only the person at the VM's screen. The client asks only when all hold,
  else it exits 1 at once (logind via `loginctl`):
  - `PAM_USER` is a person (uid 1000 or more, never root) and owns the
    active, local display session on a seat (`show-user -p Display`:
    `Remote=no`, `Active=yes`, a seat, class `user`). So polkit's
    `auth_admin` for a user outside wheel (identity root or another admin)
    and sudo with `rootpw`/`targetpw` never ask.
  - The caller's own login session (the audit session of sudo, or of a
    setuid polkit helper) is not remote and is this user's: on a seat, or
    the user's service manager (class `manager`: Omarchy starts Hyprland
    through uwsm, so every terminal runs under `user@<uid>.service`, audit
    session = the manager's). An SSH login, a cron job (class
    `background`), an audit session logind does not know (cronie sets
    one) or another user's session: no. No audit session at all (polkit
    127's socket-started helper) leaves it to the display session.
  - sudo: `PAM_TTY` is a terminal (`pts/N`, `ttyN`) the user owns. `sudo
    -n` from a program in the background has none and never reaches the
    Mac. The terminal goes into the dialog text.
  - polkit: the polkit rule noted a check for this user less than 5 s ago
    (see below).
  Someone logged in over SSH as another user never puts a dialog on the
  Mac. Logged in over SSH as the same user, `systemd-run --user --pty sudo`
  runs under the user's service manager and can: that is the user's own
  programs (Consequences), not a new boundary.
- What the request says (descriptive only; the guest can lie, and only
  about itself):
  - sudo: `kind: "sudo"`, the command from `/proc/<sudo pid>/cmdline`
    (sudo is setuid, the caller cannot change it after exec) and `tty`.
    Only a command the dialog can show whole and honestly: a `NAME=value`
    word anywhere (sudo allows `sudo LD_PRELOAD=... pacman`; padding in
    front would push it out of sight) or more than 120 characters: no
    Touch ID, the password, and the client says why. Anything but plain
    ASCII is shown as `?`, never dropped.
  - polkit: PAM has no action id. A polkit rule
    (`/etc/polkit-1/rules.d/00-omacvm-touchid.rules`, `00-` so it runs
    before any rule that answers) notes each check of a local, active
    subject with `polkit.spawn` of a small sh writer
    (`omacvm-touchid-note`, about 5 ms) as one line `<time> <action>`
    added to `/run/omacvm-touchid/<user>` (polkitd's folder, 0700), and
    returns `NOT_HANDLED`, so polkit's own decision stays. The client
    reads the last 15 s, leaving out actions whose own file says an active
    user is never asked (`allow_active` `yes` or `no`: the desktop checks
    those all the time). No such note under 5 s old: no Touch ID (the
    password). Exactly one action in the 15 s: `com.1password.*` becomes
    `kind: "1password"`, anything else `kind: "polkit"` with the action
    id. More than one: `kind: "polkit"` without an action ("allow a system
    request"). So a program that runs `pkexec` and then a harmless
    `pkcheck --action-id com.1password.1Password.unlock` gets the generic
    text, never "unlock 1Password". An action made to ask by a local rule
    although its file says `yes` gets no note that counts: the password.
- Transport: Parallels, UTM, Fusion: TCP to the Bridge as today (`/proof`,
  token, then the signed request). OmacVM.app: a new virtio port
  `org.omacvm.auth`, root 0600 by udev rule, so the control centre's port
  (one opener, held up to 60 s by status requests) never blocks a sudo.
  The app relays it like `org.omacvm.control`.
- Timeouts in the client: 1 s to connect, 35 s for the answer, and one
  deadline of 40 s for the whole request (a "Bridge" that drips a byte at a
  time cannot hold sudo or the agent), then exit 1. Ctrl+C in sudo kills
  the client; the agent's Cancel kills the helper, and the client, which
  watches its parent, stops too; either way the closed connection cancels
  the Mac dialog.

### Request and answer

`POST /omacvm/touchid`, signed as in ADR 0031 but with the Touch ID key
and its own label (`"omacvm-touchid-request 1\n"` ...), so a control
centre signature never counts here and the other way round. Body, strict
JSON, at most 1 KB, unknown keys refused:

```json
{"kind": "sudo" | "polkit" | "1password", "user": "vincent",
 "detail": "pacman -Syu", "tty": "pts/3",
 "action": "org.freedesktop.systemd1.manage-units"}
```

`user` is `[A-Za-z_][A-Za-z0-9_.-]{0,31}` and never `root`; `tty` is
`pts/N` or `ttyN`; `detail` up to 200 bytes, `action` up to 128
(`[A-Za-z0-9._-]`). The Mac turns control, bidi, invisible and unusual
space characters into one plain space (for a client that is not ours) and
cuts `detail` at 120 characters with "… (cut)" (ours never sends longer).

Answer, signed with `X-OmacVM-Answer` (nonce, status, body hash):

```json
{"result": "yes"}
{"result": "no", "reason": "cancelled" | "failed" | "timeout" | "busy"
   | "rate" | "locked" | "not-front" | "no-touch-id" | "lockout" | "off"}
```

The client exits 0 only on a 200 with `result: "yes"`, a valid answer
signature and its own nonce. Everything else, including an unsigned answer
or no answer, is exit 1 (password). The one unsigned answer it reads is a
403 `off` (no key on the Mac, so it cannot sign), and only to say "Touch ID
off".

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
  request every 2 s, 10 a minute; after 3 misses in a row (`cancelled`,
  `failed` or `timeout`) a pause of `rate`: 60 s, then 5 min, then 30 min,
  until a yes. So a VM that keeps dialogs up for nobody stops after three.
  A dialog not answered in 30 s is invalidated (`timeout`); a client that
  disconnects invalidates it too.
- The Mac's state (screen locked, app in front) is read on the main thread.
- Nothing about the finger leaves the Mac: macOS gives the Bridge only
  success or an error code, and the VM only gets yes or no.
- Log: one line per request (VM, kind, result, never `detail`); refusals
  and the fast `rate`/`busy` noes at most once a minute per kind.

### Texts

macOS shows: "OmacVM Bridge is trying to <reason>. Touch ID to allow this."
So the reason starts with a verb:

| kind | reason |
|---|---|
| `1password` | `unlock 1Password in Omarchy` |
| `sudo` | `run sudo in Omarchy (pts/3): <command>` |
| `polkit` with action | `allow "<action id>" in Omarchy` |
| `polkit` without | `allow a system request in Omarchy` |

With several VMs set up, " (<VM name>)" follows "Omarchy" (for sudo:
"Omarchy (<VM name>, pts/3)").
In the VM, the client's one line (PAM info):

- asking: `Touch ID on your Mac, or wait for the password prompt`
- fast no: `Touch ID not available (<why>), use your password`, why from
  the reason: `Mac locked`, `VM not in front`, `no Touch ID`, `too many
  tries`, `Touch ID off`, `VM clock off`. Silent for
  `cancelled`/`failed`/`timeout`; the password prompt is the message.
- a sudo command it does not send: `Touch ID not used for this command
  (too long or sets variables), use your password`

Control centre and CLI: the row "Touch ID" with "Unlock 1Password, sudo
and system prompts with the Mac's Touch ID. Your password keeps working."
`omacvm enable touch-id`, `omacvm disable touch-id`. `omacvm check`
reports: the keys in the VM, the PAM lines, the polkit rule and its note
writer. Not yet: a row in `omacvm check --mac-only` (key on the Mac,
sensor) and the last result.

## Consequences

- A yes protects only the VM's own boundary, the same as the VM password:
  it never unlocks anything on the Mac, and macOS asks again every time.
  Anyone who has root in the VM has the key and can ask for dialogs; a
  yes then gives them nothing they did not have.
- The desktop user's programs cannot ask directly (no key), but they can
  run `sudo` or `pkexec` and so put up a dialog. Without a terminal they
  could not pass sudo before, and with Touch ID they still cannot reach
  the Mac (no `PAM_TTY` of the user's: password). A program can open a
  terminal of its own (a new pty is the user's) and run sudo in it; the
  dialog then names that terminal ("pts/7") and the command. What the text
  can prove: the command sudo was started with, whole, and the terminal
  number. What it cannot: that the person typed it. The "VM in front" rule
  keeps dialogs from appearing while the person does something else on the
  Mac, and a dialog the person did not expect is a reason to cancel.
- The sudo command goes to whoever passes `/proof`: any VM with the Bridge
  token that takes the Mac's address can read it (it gets no yes). Do not
  put secrets on sudo's command line (that holds without Touch ID too).
- `touch_id_password_fallback` (`.deviceOwnerAuthentication`) also
  accepts an Apple Watch's approval and the Mac's password, as macOS does.
- polkit's helper may use the network to the Bridge's address (the
  drop-in above); polkit's other sandboxing stays.
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

- Review fixes (Fable 5.1, 2026-10-06): label only for a single noted
  action (H1); the display session and the caller's session from logind,
  uwsm terminals included (H2, M1, M5); sudo only from a terminal of the
  user's, named in the dialog (H3); no cut or `NAME=value` commands, `?`
  for non-ASCII, more characters cleaned on the Mac (M3); one 40 s
  deadline (M2); timeouts count as misses, growing pauses (M4); the
  smaller ones (main thread, fast noes in the log, unsigned `off`, `VM
  clock off`, `sudo-i`, user names with dots, the client stops with its
  caller, a sh note writer).
- Test VM pass (2026-10-06, OmacVM.app test VM on the MacBook Pro, Arch
  ARM: sudo 1.9.17p2, polkit 127, systemd 262, Hyprland 0.56 through uwsm;
  the real PAM stacks and polkit, a stand-in Bridge on 127.0.0.1 in the
  VM, no Touch ID dialog anywhere): sudo in a foot terminal started as
  Omarchy starts it (uwsm app): Touch ID asked, `{"kind":"sudo",
  "detail":"true","tty":"pts/0"}`, let in, 47 ms; `pkexec true`: asked
  (`org.freedesktop.policykit.exec`), let in, 98 ms; a stand-in
  `com.1password.1Password.unlock` (`allow_active` `auth_self`) through
  `pkcheck --allow-user-interaction`: `kind "1password"`, let in; right
  after a pkexec, the generic text. Over SSH: sudo and pkexec never ask
  (password prompt at 55 ms and 105 ms). `systemd-run --user sudo -n`:
  never asks. Bridge down: sudo's password prompt at 66 ms, polkit's
  client done 82 ms after pkexec started; a Bridge address that does not
  answer: 1.08 s. Without the helper drop-in, pkexec never reached the
  stand-in (the sandbox). The polkit rule costs about 5 ms per check of a
  local subject (11 ms against 6 ms).

Still to do:

- OmacVM.app: the `org.omacvm.auth` virtio port and its relay in the app.
  Until then the client says "Touch ID not available (OmacVM.app: not
  yet)" on the app's VMs and the password prompt comes.
- The manual check with a real finger (the person, on a Mac with Touch ID,
  a Parallels, UTM or Fusion VM): `omacvm enable touch-id`, then in an
  Omarchy terminal `sudo -k; sudo true` (Touch ID dialog "run sudo in
  Omarchy (pts/N): true", touch: no password); again and Cancel on the Mac
  (the password prompt); `pkexec true` (dialog "allow
  "org.freedesktop.policykit.exec" in Omarchy", touch); the Mac locked or
  another app in front (password at once); 1Password's "Unlock using
  system authentication" after its first unlock ("unlock 1Password in
  Omarchy").
