# OmacVM.app

Omarchy in its own Mac app, without Parallels, UTM or VMware Fusion. The app
brings QEMU (built from try-omarchy's patched source) and runs it with Apple's
Hypervisor framework. The GPU goes through VirGL on the Mac's OpenGL.

Source: [`app/`](../../app/README.md) in this repo (the launcher, QEMU's build
scripts and patches, the VM build script); it carries OmacVM's `src/` and has
OmacVM's version.

## Get it

OmacVM.app needs macOS 15 or newer on an Apple Silicon Mac (the other
routes run on macOS 14).

- `omacvm build --vm-type app`: when the app is missing, OmacVM offers to
  download it (below) and goes on with the build.
- Or download `OmacVM-<version>.zip` from the
  [releases](https://github.com/gillesgoetsch/omacvm/releases) (signed with
  a Developer ID), unzip it and open it: it offers to install itself in
  Applications, keeping that signature (under another name it is signed
  again ad hoc). A newer download starts on the name and folder of the copy
  you installed before, so Install replaces it in place. Run Without
  Installing counts for that copy only: the next download asks again. Updates
  (`omacvm update`) never ask. Downloaded with a
  browser, macOS blocks it the first time: click Open Anyway in System
  Settings › Privacy & Security.

`omacvm update` replaces an older OmacVM.app with the one for its version
(not while the app is open), and keeps the name it was installed under.
The app also updates itself, once a week unless switched off, never while a
VM runs, and goes back by itself when a new version does not start
([app README](../../app/README.md#updates)).

## What works

- Setup in the app: VM name, user, password, resources, disk size, the VMs
  folder (any APFS or Mac OS Extended drive).
- Where things are: the app in `~/Applications`, the VMs in
  `~/OmacVM/<VM name>/`; moves, other drives, sizes and downloads:
  [where things are](#where-things-are).
- A VM folder from another Mac: copy it into `~/OmacVM/` once (the app runs
  one VM at a time, the first folder by name). Check that the app looks there:
  `~/Applications/OmacVM.app/Contents/MacOS/OmacVM --vms-folder` (or the
  same under `/Applications`) must print the same as `echo ~/OmacVM` (a home
  folder can be on another drive, under `/Volumes`). If it prints another
  folder, move the VM folder there and use that path below. Open the app and
  start the VM. Then, with the VM running, set up this Mac's side (Bridge, Gestures, clock, token) with
  `bash ~/Applications/OmacVM.app/Contents/Resources/scripts/apply-vm.sh ~/OmacVM/<VM name>`
  (or `omacvm apply --vm "<VM name>" --vm-type app`). If it says there is no
  SSH access, the VM does not know this Mac's key yet: `omacvm apply` prints
  the one command to run in the VM's terminal.
- The build: the same steps as the other routes (try-omarchy as a temporary
  live system, Arch Linux ARM on btrfs with GRUB, Omarchy from omarchy-mac,
  OmacVM's VM side). 10 to 30 minutes (8 on an M4 Max), plus a 1.4 GB
  download the first time.
- A normal install: boots through UEFI and GRUB, so `omarchy update` and
  snapshots work.
- The window: Omarchy follows its size and the display's refresh rate
  (120 Hz on a MacBook Pro).
- GPU in browsers: WebGL 1 and 2 on the hardware in Chromium, Google Chrome,
  Brave and Firefox (`virgl (Apple M4 Max)`), no flags.
- Video decoding on the Mac's media engine (since 2.7.0): H.264, VP9 and AV1
  in Google Chrome (YouTube 4K at 60 fps, the VM's CPU nearly idle), VP9 in
  Brave, H.264 and VP9 in Firefox (AV1 not yet), H.264, VP9 and HEVC in mpv,
  FFmpeg and GStreamer apps. Omarchy's Chromium (Arch Linux ARM) is built
  without VA-API: H.264 and VP9 (YouTube) go through a V4L2 decoder OmacVM
  adds to the VM (feature `chromium-video`, on by default). [How it works](../video-decode.md).
- A new frame goes to the window as soon as Omarchy finishes it, drawn off
  the main thread as an IOSurface (before, QEMU redrew the window on a 30 ms
  timer). GPU fences come back in about 0.2 ms instead of 1.5 ms, so light 3D
  work runs two to three and a half times as fast (glmark2's short set
  2,800-3,700 instead of 1,000-1,500). WebGL-heavy pages stay the same on a
  quiet Mac (Aquarium 21-23 fps): there Apple's OpenGL is the limit. While
  other VMs use the Mac they ran about 10% slower than with the old path;
  with only the CPU busy, about 15% faster ([how](../architecture/graphics.md)).
  If the picture or the GPU misbehaves on a Mac: `defaults write
  org.omacvm.app gpuSafeMode -bool true` and restart the VM goes back to the
  2.8.0 fence and frame path; `omacvm check` shows which path a VM took.
- Vulkan in the VM (Venus on MoltenVK), hidden and experimental:
  `defaults write org.omacvm.app venus -bool true`, then restart the VM. The
  VM's Mesa must round GPU memory to the Mac's 16 KiB pages (Mesa 26.2.4 or
  newer; Arch Linux ARM has 26.2.3, so
  [`app/scripts/dev/guest-mesa-venus.sh`](../../app/scripts/dev/guest-mesa-venus.sh)
  builds the Venus driver into `/opt/mesa-venus`); otherwise Vulkan apps fail
  to get memory. vkmark about 5,200. OpenGL stays on virgl.
- Quit, the window's close button, logging out and restarting the Mac shut
  Omarchy down cleanly first. The Mac's sleep pauses the VM; after waking,
  the VM's clock is set to the Mac's.
- Full screen, like Parallels; on a MacBook with a notch Omarchy's bar goes
  beside the notch ("Use the notch for the menu bar", below).
- Every Mac display in full screen: with an external display connected, full
  screen opens a window on each Mac display (each in its own Space) and
  Omarchy gets one output per display (Virtual-1 the main window, Virtual-2,
  ...), each at that display's resolution, scale and refresh rate, placed as
  in macOS's arrangement. Plugging a display in or out works live: its
  workspaces move to the main display and come back with it, as on a
  laptop. Leaving full screen closes the other windows; in a window Omarchy
  has one screen. Omanotch's strip stays on the MacBook whichever display
  holds the main window: the app tells the VM which output is the built-in
  display. Omarchy's display panel (the monitor icon in the bar) has
  **Use external displays**: off, full screen stays on one display. The VM
  keeps the setting (`~/.config/omacvm/displays.conf`; also
  `omacvm-displays external on|off`).
- ⌘ shortcuts (⌘Space too) go to Omarchy as Super in full screen, through
  OmacVM Gestures, as on UTM: the app needs no Accessibility of its own.
  With the gestures feature off the VM does not talk to Gestures, so these
  shortcuts stay with macOS.
- A feature switched off gets nothing of the Mac: from the VM's next start
  the app keeps that feature's port on the Mac (Omanotch, Gestures, Bridge)
  closed to the VM and does not serve its battery or camera port.
  `omacvm apply` writes the VM's features into its folder (`features`); a
  VM without that file gets everything, as before. On the fast network the
  VM reaches the Mac directly: there only the VM side keeps it away.
- The app reads the features only when the VM starts. A feature turned on
  while the VM runs (`omacvm enable bridge`) gets its link to the Mac at the
  next start: shut the VM down and start it again. `omacvm apply` names
  such features, and `omacvm check` fails on them until then.
- On a MacBook with a notch, "Use the notch for the menu bar" (on by
  default): full screen covers the strip beside the notch too and Omarchy's
  bar goes there, but that full screen has no Space of its own (macOS 15
  keeps full-screen Spaces below the notch). Switched off, full screen is in
  its own Space below the notch. The switch shows only while the Mac's
  built-in display has a notch; elsewhere it is off.
- Install under a name: OmacVM, Omarchy or your own; it shows in the Dock.
- Clipboard both ways, text and images (try-omarchy's agent, over a virtio
  port, not the network).
- Sound through the Mac (QEMU's HDA card; PipeWire in the VM), and the Mac's
  microphone: the app asks for it when it starts a VM, because QEMU cannot
  ask itself and records nothing without it ([finding 22](../troubleshooting.md#22-parallels-fusion-app-the-microphone-records-nothing-or-silence)).
  Until you allow it, the VM starts without recording (QEMU would wait
  minutes for an answer): allow it, then restart the VM. QEMU starts the
  recording on a thread of its own, so the VM never stops for it; until the
  microphone runs, the VM records silence.
- The Mac's camera as *Mac Camera* (`/dev/video42`): QEMU has a virtio port
  `org.omacvm.camera`, the launcher serves it with the Bridge's camera code
  (`src/bridge/mac/camera.swift`) and turns the camera on only while a Linux
  app reads it. macOS asks for the camera for OmacVM the first time.
- The Mac's battery in Omarchy's bar, on a MacBook: charge, charging and
  Omarchy's battery panel; time left and the low-battery warning are not
  tested yet with the Mac on battery (try-omarchy's bridge, over a virtio
  port; [how it works](../../src/battery/README.md)).

## Where things are

- **The app**: `~/Applications/OmacVM.app`, your own Applications folder
  (updates need no administrator). An app in /Applications keeps working;
  it offers once to move itself to ~/Applications (one rename on the Mac's
  disk, the signature stays). `omacvm` and its updates find the app in
  either place.
- **The VMs**: `~/OmacVM/<VM name>/`, one folder per VM: `vm.env` (the
  settings), `disk.img` (the disk; sparse: it takes what it holds, not its
  full size), `efi-vars.fd`, `logs/`. To take a VM to another Mac, copy its
  folder into that Mac's VMs folder (the VM must be shut down; above) with
  `cp -R`, which keeps the disk sparse (`ditto` wrote it in full). Where
  something else already has the name ~/OmacVM (a file, a git clone
  ~/omacvm: the same folder on a case-insensitive disk), new VMs go to the
  old place below instead.
- **Another VMs folder** (an external drive, say): in the setup, or in the
  settings under Storage › Change. With VMs there already, the app asks:
  **Move** (on the same drive a rename; to another drive copied, read back
  and compared, then deleted in the old place, with progress and a Cancel
  that leaves the VM where it was), **New VMs Only** (the VMs stay where
  they are and keep working from there) or Cancel. A VM that runs is never
  moved: it stays, and the app says so. If a file in the VM's folder changes
  or appears during a move (an `omacvm apply`, say), the copy is deleted and
  the VM stays where it was; try again. A VM folder that is a link to
  another folder is not moved: move the folder it points to in Finder. A
  half copy (`.NAME.moving`) left by quitting during a move is deleted the
  next time the app opens.
- **A drive that is not connected**: the app says so ("SD4TB is not
  connected") instead of offering a new VM, and builds nothing there (a
  leftover empty /Volumes/NAME folder counts as not connected). A VM whose
  files went missing says which, and does not start.
- **2.9 and older** kept the VMs hidden in
  `~/Library/Application Support/OmacVM/VMs`. They keep working there; the
  app offers once to move them to ~/OmacVM (Storage › Move later too).
  `omacvm` finds VMs in every folder the app does. Going back to 2.9.0
  after that: it shows only the VMs in ~/OmacVM (or the picked folder); the
  others are hidden from it, not deleted.
- **Sizes**: the settings show each VM's size on disk (with Show in Finder)
  and the downloads in `~/Library/Caches/omacvm` (try-omarchy's live system,
  prebuilt VMs) with **Clear Downloads** (not while a build uses them).
- **Backups and search**: Time Machine leaves VM folders out (the disk
  changes all the time). Spotlight never reads a VM's disk (it has no
  importer for it), but lists the files' names; macOS has no switch an app
  can set for one folder, so to hide them add ~/OmacVM in System Settings ›
  Spotlight › Search Privacy.

## From the omacvm command

`omacvm build --vm-type app` (or OmacVM.app in the build's first question)
builds the VM through the app instead of in it. The questions and the summary
are the same as for the other routes; the VM goes into the app's VMs folder
(~/OmacVM, or the one set in the app; no `--vm-dir`; a drive that is not
connected stops it, exit 3). Then:

1. It finds the app in ~/Applications or /Applications by its bundle id
   (`org.omacvm.app`, under any name it was installed as). Not installed:
   after asking, it downloads `OmacVM-<version>.zip` (this OmacVM's version)
   from the GitHub release `v<version>` with curl, checks it against the
   `.sha256` next to it and that the app is signed with OmacVM's Developer
   ID (team 722686Y34B), and puts it in ~/Applications. curl sets no quarantine attribute, so
   Gatekeeper does not stop the app. Releases from before the app have no
   zip: it says so and stops (exit 3). With `--yes` it installs nothing and
   stops with the command to run (exit 3).
2. It writes the VM's `vm.env` as the app does (name, CPUs, memory, disk,
   a free SSH port from 52222, user, hostname, timezone, language, keyboard,
   features) and runs the app's `Contents/Resources/scripts/create-vm.sh`
   with the password on stdin: the same script and steps as a build in the
   app. It leaves the VM shut down.
3. `omacvm apply` from this checkout, which starts the VM in the app, then a
   reboot, as on the other routes.

No Homebrew tools are needed (the app brings QEMU and zstd). OmacVM.app runs
one VM at a time: the build stops at the start while another one runs.

## What needs a person

- The password for Omarchy, typed in the setup.
- macOS asks whether OmacVM may find devices on local networks the first
  time the Developer ID build starts a VM: allow it.
- The permissions OmacVM's Mac helpers ask for (as on the other routes).

## Not done yet

- The Bridge's features (Wi-Fi, Bluetooth, media keys and the rest) and
  trackpad gestures: the build installs Bridge and Gestures on the Mac and
  they accept the VM on 127.0.0.1 (below), but these are not confirmed on
  this route yet.
- Every Mac display: up to five (the window and four more). Tested with one
  real external monitor and with virtual displays; two or more real
  monitors are not tested yet.
- When another app takes over a display (it shows that app's desktop there)
  or the display with the main window is unplugged and plugged in again,
  macOS may leave the other display on its desktop after you come back to
  OmacVM. Swipe to OmacVM's Space on that display (Control-arrow or
  Mission Control); the pointer goes to Omarchy again once its window shows.
- The app needs Xcode's Command Line Tools (it builds OmacVM's Mac helpers);
  it checks for them before a build and offers to install them.

## How it talks to the Mac

QEMU's user network: the Mac is `10.0.2.2` for the VM, and the Mac reaches
the VM's SSH on `127.0.0.1:<port>`.

- The VM reaches only three of the Mac's local ports through `10.0.2.2`:
  47811 (Omanotch), 47830 (Gestures) and 47831 (Bridge). Everything else the Mac runs on
  127.0.0.1 (dev servers, databases) is refused, like on the other routes.
  The app's QEMU carries a libslirp patch for that
  (`OMACVM_SLIRP_HOST_PORTS`).
- The clipboard and the Mac's battery do not use the network: each has its
  own virtio port (`org.omacvm.clipboard`, `org.omacvm.battery`) on a socket
  only the app's user can open. So do the displays (`org.omacvm.display`,
  below). The battery goes one way; the VM can only ask
  for a fresh reading.
- Gestures and Bridge also listen on the Mac's 127.0.0.1, where any Mac
  program could connect, or listen in their place while they are not
  running. So the VM gives the Bridge's token to neither before it has proved
  it knows it (HMAC-SHA256 of a fresh nonce and the Mac address it answered
  on, which must be 127.0.0.1: a proof passed on from the helper on
  10.211.55.2 fails): Gestures then wants the VM's own proof (the token
  never goes over the wire, and the VM acts on no key or gesture before the
  proof); the Bridge gets the token on each request after `GET /proof`.
  The app makes the token when the Bridge has not, and puts it into the VM.
- Not covered yet, so the token is not safe from Mac programs on this route:
  VMs set up before the proof still send the token straight away (to
  whatever listens) until their next `omacvm apply`, and so does an
  Omanotch installed before it came with OmacVM (its notchcast sends
  `auth <token>` to 47811). The Omanotch in `src/omanotch` proves it the same
  way (`mac/Sources/GuestAuth.swift`).
- Omanotch (47811) needs a version that serves 127.0.0.1; `omacvm apply` and
  `omacvm check` say when the one on the Mac is older.
- `omacvm apply` writes `guest-pointer` into the VM's folder once the VM
  draws Omarchy's own pointer; VMs set up before that still need the Mac's
  pointer (QEMU's `show-cursor=on`).
- The VM's window takes the pointer without a click: on the first motion
  over the VM, and when the window becomes key, the app comes to the front
  or the window goes full screen with the pointer on it (after a start, a
  reboot in the VM, Command-Tab or the escape combo). Not after
  Ctrl+Option+G until the pointer left the window. The Mac's pointer over
  the VM hides only once Omarchy draws its own (its display agent said
  hello on `org.omacvm.display` since the VM's last reset), so one pointer
  is always there while the VM boots (`omacvm-cocoa-pointer-start.patch`,
  rules in `omacvm-cocoa-pointer-start-logic.patch`, unit test
  `app/runtime/Tests/display/test-pointer-start.sh`; in a VM:
  `src/tests/pointer-start-vm.sh`). QEMU's log says which way it takes
  ("cocoa: pointer: ..."). Off (QEMU's own way, on entering the window or a
  click): `defaults write org.omacvm.app pointerStart -bool false`.

## Fast network (experimental, off by default)

`omacvm enable fast-network --vm NAME`, or **Fast network (experimental) ›
Turn On…** on the VM's screen in the app, puts the VM on macOS's own VM
network (vmnet, shared mode, as Parallels and UTM) instead of QEMU's user
network.
The VM gets an address of its own on a network of its own, `192.168.77.0/24`
(the Mac is `192.168.77.1`), and traffic between the VM and the Mac no
longer goes through one QEMU thread. Measured: see
[the numbers](../benchmarks/README.md#fast-network-omacvmapp).

- vmnet needs root or Apple's `com.apple.vm.networking` entitlement, which the
  app does not have. So turning it on installs a small system service,
  `omacvm-netd` (`src/net/mac`), and macOS asks for your password once (sudo
  in the terminal for `omacvm`, macOS's password dialog for the app's button).
  The button never runs by itself; a cancelled dialog changes nothing. For
  app VMs the VM's `fast-network` file is the switch: the button, `omacvm
  enable`/`disable`, `omacvm apply` and `omacvm check` all go by it. It comes built and signed inside OmacVM.app (Developer ID for
  published apps; no Xcode needed); apps from before that build it from
  source. launchd starts it when a VM connects; it quits a minute after the
  last connection.
- The service only takes connections from OmacVM.app's QEMU run by a Mac user
  who enabled it: it checks the connecting process's user and code signature
  (OmacVM's Developer ID team, or for an app built from source exactly that
  build: enable it again after a rebuild). It makes one vmnet interface per
  VM, isolated from the other VMs' interfaces, and does nothing else: no
  commands, no files, no other requests.
- Its own network, not UTM's `192.168.64.0/24`: while UTM (or another app)
  has that one up, vmnet refuses an isolated interface on it. With its own,
  UTM VMs and the fast network run side by side (tested on the Mac mini).
  Each refused start costs macOS's vmnet service a descriptor it never gives
  back (at 256 vmnet stops working on the whole Mac until a restart), so after
  a failed start the service waits 30 s before the next one, doubling up to
  an hour while it keeps failing, and after 8 failures in a row it stops
  trying until the Mac restarts or `omacvm enable fast-network` runs again
  (`omacvm check` says so). It keeps that count in
  `/var/run/org.omacvm.netd.state`, so quitting when idle does not reset it.
  After a failure it also does not try while another program's VM network
  holds `192.168.77.0/24` (a bridge with those addresses that is not its
  own): one failed start per conflict, not one a minute. When another
  interface (a LAN, a VPN) already has addresses in `192.168.77.0/24`, the
  app does not try and takes QEMU's user network, saying why.
- When macOS's vmnet service (InternetSharing) stops or crashes, every VM
  interface on the Mac goes with it, but vmnet tells no one. The service
  watches that process and closes its connections when it exits; QEMU
  connects again at once and gets a new interface (tested: the VM answered
  again 3 s after the kill). Parallels' shared and host-only networks are
  gone after such a restart too, and Parallels does not notice: quit and
  reopen Parallels Desktop, or `sudo killall prl_naptd` (its watchdog starts
  it again within about a minute, with its networks).
- The app picks the network at each start: the fast network when the VM has
  it (its `fast-network` file, with its own MAC address), the service is
  there and would take this app's QEMU; else QEMU's user network as before.
  While the VM runs, the app watches the link (every 3 s): when vmnet stays
  down (service gone, vmnet refusing), it plugs a second network card on
  QEMU's user network into the VM and takes the first one's link down (the
  VM's NetworkManager moves over within seconds); when vmnet is back for 15 s,
  it swaps back. A switch that fails (QEMU's monitor busy) is tried again
  every 3 s, adding only what is not there yet. `logs/network` and
  `qemu.log` say which network the VM has and why; `omacvm check` shows it,
  with the service's last refusal.
- On the fast network the Mac reaches the VM's SSH on its own address (from
  macOS's DHCP leases), with the same remembered host key; the VM lets SSH in
  from `192.168.77.1` only (every app VM allows it since this version, so the
  `omacvm` command still reaches a VM the app's button moved). The VM's
  Bridge, Gestures and Omanotch (notchcast) find the Mac at the gateway and
  prove it with that address; the Mac's Bridge, Gestures and Omanotch listen
  there too and count those VMs as the app's. When the app
  moves the VM between the two networks, the VM's Gestures and notchcast see
  the new gateway and connect again within a second (tested both ways; on the
  Mac, Omanotch drops the old connection when the same VM, by name, comes in
  on the other network). On the Mac
  the old connection goes in one of two ways: TCP keepalive drops it in
  about 10 s when its path went away (the fast network); on the user network
  QEMU itself keeps answering for the VM, so keepalive never fires, and the
  Mac drops it when the same app VM (by name) connects from the other
  address. So two running app VMs with the same name (an APFS clone before
  `omacvm apply` renames it), one on each network, push each other out of
  Gestures every 2 s: give clones their own name.
- `omacvm disable fast-network` (or **Turn Off…**) goes back at the next start; when none of
  your app VMs has the fast network any more it also removes the service
  (a VM still running on it then moves to the user network at once).
  `omacvm uninstall` removes it for your Mac user, and from the Mac when no
  other user has it.

What is missing before it can become the default: [below](#fast-network-not-done-yet).

### Fast network: not done yet

- Tested on a Mac mini (macOS 27): SSH, DNS, IPv6, the Bridge (proof on
  `192.168.77.1`), a UTM VM on UTM's shared network at the same time, the
  service going away and coming back under a running VM (user network after
  7 s, vmnet again after 13 s), a start with the service unreachable (user
  network after 17 s), vmnet refusing (back-off), a restart of the service
  (QEMU reconnects, about 1 s without network), the VM paused for a minute (as
  over the Mac's sleep), refused callers (another program, another user),
  macOS's vmnet service killed under a running VM, another program holding
  `192.168.77.0/24` while the VM starts (one failed start, user network,
  vmnet again once it was gone), the Gestures link across network switches
  (with the helper's own handshake code: the mini's Gestures helper waits
  for its permissions, so no real swipes), Omanotch's link (notchcast on
  `192.168.77.1`, and across a switch to the user network and back), two app
  VMs on the fast network at once (isolated from each other, both with
  internet, DNS, IPv6 and Omanotch).
- Two app VMs at once need two launchers: the app runs one at a time (a
  second start hands over to the first), so today that takes a copy of the
  app with its own bundle identifier.
- Not tested yet: VPN clients on the Mac, a real sleep and wake, Wi-Fi
  changes while the VM runs, real trackpad gestures over the fast network
  (the choice of VM is covered by `src/gestures/mac/test.sh`), Omanotch's
  strip on a MacBook with a notch over it (the link is tested), the app's
  password dialog end to end (its arguments are covered by
  `src/net/mac/test.sh`), and the MacBook (numbers there too).
- SMAppService would give macOS's own approval (System Settings) instead of
  a password dialog; not done.

## Every Mac display

QEMU's macOS window (its "cocoa" display) showed one guest screen. OmacVM's
QEMU patch (`app/runtime/patches/omacvm-cocoa-displays.patch`) gives it a
window per guest screen:

- The VM has a virtio-gpu with five outputs. In full screen, each other Mac
  display gets a window of its own, full screen in its own Space, showing
  the next output; QEMU tells the VM that output's size, scale (as the EDID's
  pixel density) and refresh rate, as for the main window. Outputs without a
  window are disconnected.
- Linux's virtio-gpu driver has no place for an output's position, so the
  arrangement goes over a virtio port, `org.omacvm.display`, from QEMU's
  window code to `omacvm-displays` in the VM (a user service), which writes
  it for `omacvm-display-sync`; that places each output as the Mac's
  displays are. A display with its own rule in `monitors.lua` keeps it.
- QEMU opens the other windows only after `omacvm-displays` said hello on
  that port (a VM without it keeps one screen) and while the switch is on.
  It applies the VM's switch at most once a second, and it takes only
  numbers it can use from the port: anything else is ignored.
- The pointer: the VM has one tablet, and Hyprland spreads it over the box
  around all its outputs. `omacvm-displays` reports where Hyprland put each
  output, and QEMU points the tablet at the matching spot of that box, so
  the pointer lands where it is on the Mac, also with Omarchy's zoom.
  The other displays' windows take the pointer (and with it the keyboard)
  only while OmacVM.app is in front, or on a click; another app coming to
  the front gets both back.
- A drag keeps the pointer from one display to the next, also across the
  menu bar strip above a full-screen window on a MacBook with a notch, so
  ⌘-dragging a window moves it to the other display. QEMU reads the
  modifier keys only from input events
  (`qemu-cocoa-modifiers-input-only.patch`): the pointer entering another
  window comes without them and used to let go of Super mid-drag.
- On a Mac with a notch, macOS's full screen ends below the menu bar, a few
  points lower than the screen's safe area. Each output gets its window's
  real size once the window is in full screen
  (`omacvm-cocoa-fullscreen-size.patch`), so the picture is not squeezed
  and the pointer is exact. For the main window that size is the area macOS
  gives full screen, not the view: the view is letterboxed while the guest
  reboots, and sizing from it shrank the output on every reboot
  (`omacvm-cocoa-fullscreen-area.patch`).
- Two outputs switched at once could leave Linux with an old list (it
  clears the display event after reading); a small virtio-gpu patch
  (`qemu-virtio-gpu-display-event-race.patch`) raises the event again.
- A display with only Hyprland's dark grey (no wallpaper, no bar) means the
  shell draws nothing there. The cause found: QEMU refused the memory of a
  big texture (the wallpaper) when it came in more than 16384 pieces, as it
  does in fragmented guest memory, and virglrenderer then dropped the
  shell's GPU context (`qemu-virtio-gpu-mapping-entries.patch` allows 262144
  pieces: at least 1 GiB even when every piece is a single 4 KiB page).
  `omacvm-displays` also looks at what each display shows (a small
  screenshot) after the shell starts and after the layout changes; a display
  that shows only the grey with no window on it gets the shell restarted
  (not while locked, at most every 2 minutes, 3 times per session, not again
  when a restart changed nothing; `repair-shell=off` in
  `~/.config/omacvm/displays.conf` turns that off). `omacvm check` says
  "desktop" in the VM and "GPU contexts" on the Mac (QEMU's log).
- Outputs move when displays come and go. Omarchy's remap for a layer
  surface left at its output's old place never fires (it waits for x/y
  signals Quickshell's screens do not have); Omanotch's patched bar and
  wallpaper remap themselves when their output moves.
- In full screen the Dock and the menu bar stay hidden on every display, and
  while the VM has the pointer the Mac's cursor never gets onto a screen
  corner or the Dock's edge: within 200 points of them it is detached and
  stays put, and the guest's pointer moves on by the mouse's own motion
  (VMs that show the Mac's cursor instead of the guest's, `show-cursor=on`:
  the cursor follows the guest's pointer, still kept off the corners and
  the Dock's edge) (`omacvm-cocoa-fullscreen-edges.patch`, maths in
  `omacvm-cocoa-pointer-guard.patch`, unit test
  `app/runtime/Tests/display/test-pointer-guard.sh`). The pointer moves the
  same there as anywhere else. The app's setting "Keep the Dock and hot
  corners away in full screen" (QEMU's `immersive`) turns both off. Whether
  hot corners stay quiet with a real mouse is still to be confirmed (with
  simulated motion the bottom-left corner fired in an earlier test).

Testing without a monitor: `app/scripts/dev/virtual-display.m` makes a
virtual Mac display (killing it is unplugging it). With
`OMACVM_TEST_SKIP_DISPLAYS=<the real displays' ids>` (and
`OMACVM_TEST_MAIN_DISPLAY=<id>` for the main window), QEMU uses only the
other displays, "full screen" is a plain window over each display (no
Space, no menu bar change) and QEMU never takes the focus.
`OMACVM_TEST_ONLY_DISPLAYS=<ids>` keeps real full screen but gives windows
only to those displays (another test's virtual display is left alone).
`OMACVM_DISPLAYS_DEBUG=1` logs what goes over the port (QEMU's log).
