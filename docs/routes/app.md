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

## What works

- Setup in the app: VM name, user, password, resources, disk size, where the
  disk goes (any APFS or Mac OS Extended drive).
- Where things are: the app in `~/Applications` (or `/Applications`, where
  older versions put it), the VMs in `~/OmacVM/<VM name>/`. VMs from before
  2.9.0 in `~/Library/Application Support/OmacVM/VMs` stay there and are used
  while `~/OmacVM` does not exist. A folder picked in the setup wins over
  both. Spotlight lists the file names in `~/OmacVM` but never reads inside a
  VM disk; to hide the folder from it, add it under System Settings ›
  Spotlight › Search Privacy.
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
  without VA-API and decodes on the CPU for now; a route for it (V4L2) is
  planned. [How it works](../video-decode.md).
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

## From the omacvm command

`omacvm build --vm-type app` (or OmacVM.app in the build's first question)
builds the VM through the app instead of in it. The questions and the summary
are the same as for the other routes; the VM goes into the app's VMs folder
(set in the app; no `--vm-dir`). Then:

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

## Fast network (experimental, off by default)

`omacvm enable fast-network --vm NAME` puts the VM on macOS's own VM network
(vmnet, shared mode, as Parallels and UTM) instead of QEMU's user network.
The VM gets an address of its own on a network of its own, `192.168.77.0/24`
(the Mac is `192.168.77.1`), and traffic between the VM and the Mac no
longer goes through one QEMU thread. Measured: see
[the numbers](../benchmarks/README.md#fast-network-omacvmapp).

- vmnet needs root or Apple's `com.apple.vm.networking` entitlement, which the
  app does not have. So `omacvm enable fast-network` installs a small system
  service, `omacvm-netd` (`src/net/mac`), and macOS asks for your password
  once. It comes built and signed inside OmacVM.app (Developer ID for
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
  from `192.168.77.1` only. The VM's Bridge and Gestures find the Mac at the
  gateway and prove it with that address; the Mac's Bridge and Gestures
  listen there too, and Gestures counts those VMs as the app's. When the app
  moves the VM between the two networks, the VM's Gestures sees the new
  gateway and connects again within a second (tested both ways). On the Mac
  the old connection goes in one of two ways: TCP keepalive drops it in
  about 10 s when its path went away (the fast network); on the user network
  QEMU itself keeps answering for the VM, so keepalive never fires, and the
  Mac drops it when the same app VM (by name) connects from the other
  address. So two running app VMs with the same name (an APFS clone before
  `omacvm apply` renames it), one on each network, push each other out of
  Gestures every 2 s: give clones their own name.
- `omacvm disable fast-network` goes back at the next start; when none of
  your app VMs has the fast network any more it also removes the service
  (a VM still running on it then moves to the user network at once).
  `omacvm uninstall` removes it for your Mac user, and from the Mac when no
  other user has it.

What is missing before it can become the default: [below](#fast-network-not-done-yet).

### Fast network: not done yet

- Omanotch over the fast network (its notchcast still looks for the Mac at
  `10.0.2.2` in app VMs).
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
  for its permissions, so no real swipes).
- Not tested yet: VPN clients on the Mac, a real sleep and wake, Wi-Fi
  changes while the VM runs, several app VMs at once, real trackpad gestures
  over the fast network (the choice of VM is covered by
  `src/gestures/mac/test.sh`), and the MacBook (numbers there too).
- The service is installed from the omacvm command (sudo in a terminal); the
  app has no button for it yet (SMAppService would give macOS's own approval
  instead).

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

## Display scale on 4K, 5K and larger displays

Omarchy's scale menu (Super+/ and its display panel) works at any scale; the
VM's screen keeps the Mac window's full size (5120×2880 on a 5K display)
and Hyprland scales the desktop. What a scale costs:

- **2x** (or another whole number) is the sharp one: every app draws at the
  screen's own size. On a 4K or larger display, OmacVM.app's display panel
  says so under the scale presets.
- **In-between scales** (1.25, 1.6, ...) look the same size as macOS's
  "looks like" settings, but apps that cannot draw at a fraction (X11 apps,
  Omarchy's own bar) draw at the next whole scale and are shrunk (1.6) or
  at the one below and stretched (1.25: a softer bar). Hyprland always
  draws the screen's full size.
- **GPU memory on the Mac** (the VM's textures and buffers, from QEMU's
  log; Omarchy's desktop with Chromium showing WebGL Aquarium and a page;
  virtual 60 Hz displays at 2x on an M4 Max):

  | Display (guest screen) | 2x | 1.6 | 1.25 | 1x | Highest, while the scale changed |
  |---|---|---|---|---|---|
  | 4K (3840×2160) | 1.1 GB | 1.1 GB | 1.1 GB | 1.2 GB | 1.6 GB |
  | 5K (5120×2880) | 1.6 GB | 1.8 GB | 1.9 GB | 1.7 GB | 2.6 GB |
  | 6K (6016×3384) | 2.0 GB | 2.2 GB | 2.1 GB (1.33) | 2.5 GB | 3.4 GB |
  | 8K (7680×4320) | 3.1 GB | 3.3 GB | 3.2 GB | 4.1 GB | 6.2 GB |

  Omarchy alone at 5K: 1.2 GB at 2x, 1.3 GB at 1.6. Scales that would not
  give whole pixels are rounded the way Omarchy does: on 5K 1.5 becomes 1.6
  and 1.75 becomes 2; on 4K and 8K 1.75 becomes 1.875.

- **Frame times** (Chromium showing a full-screen page that redraws every
  frame, `tests/graphics/fractional-scale.sh --frames`, 60 Hz virtual
  display, M4 Max, benchmark lock held): at 5K every scale kept 60 fps
  (median 16.7 ms, no late frames). At 8K: 56 fps at 2x, 49 at 1.6 and
  1.25, 39 at 1x. A Mac with a smaller GPU has less room; 2x is the
  lightest.
- **A scale change** makes every screen-sized buffer again, Hyprland's and
  every app's (20 to 50 of them, 32 to 127 MB each from 4K to 8K): Hyprland
  sets the mode 2 or 3 times (Omarchy's scale command sets it, then its
  config reload sets it again) and for a moment old and new buffers both
  count (the last column). Switching between 1.6 and 2 sixteen times
  left the same memory in use each time: nothing leaks.
- The VM's graphics memory has no fixed limit: it grows as long as macOS
  has memory to give ([Graphics memory and VM memory](#graphics-memory-and-vm-memory)).
  Up to 2.9.1 it had a budget of a quarter of the Mac's memory, which a 5K
  desktop at 1.6 with apps open could reach on a 16 GB Mac
  ([troubleshooting, finding 24](../troubleshooting.md#24-app-a-scale-like-16-on-a-5k-display-turns-the-vm-black-and-flickering)).
- The display sync (`omacvm-display-sync`) sends Hyprland a mode only when
  it shows another, one call at a time, and stops following an output that
  keeps changing (6 times in 10 s between two states, or 12 times at all)
  for a minute, then looks once more; `omacvm check` in the VM says so
  ("display sync"). A window being resized is never held.

Tests: `src/app/guest/tests/test_display_sync.py` (no VM: 4K and 5K at
Omarchy's scales, nothing sent twice, the loop guard),
`tests/graphics/fractional-scale.sh` (a running VM: every scale, mode kept,
no loop, no refused memory or lost GPU context in QEMU's log; `--frames`
adds frame times of a full-screen page).

## Graphics memory and VM memory

A Mac with Apple silicon has one pool of memory for everything: macOS, your
apps, the GPU. A VM takes two kinds from it:

- **VM memory** is the VM's RAM, the number you pick for the VM ("Resources"
  in the app, `omacvm resources`). Linux sees exactly that much. The Mac
  gives it as the VM touches it, and the VM gives back what Linux frees
  (QEMU's balloon device with free page reporting).
- **Graphics memory** is extra, on top: the textures and buffers the VM's
  desktop and apps draw with, kept by the Mac's GPU driver for the VM. It
  grows and shrinks with what is on screen: Omarchy alone at 5K about
  1.2 GB, with a browser about 2 GB, 3 GB at 8K, and for a moment more
  while the display scale changes (the table above).

The app shows both: "VM memory: 8 GB; graphics memory last run: peak 2.6 GB,
from the Mac on top". `omacvm check` has a "graphics memory" row: now, the
peak of this run, and macOS's memory pressure.

**No fixed limit.** QEMU asks macOS how much memory it can give
(`virgl-darwin-memory-pressure.patch`):

- While macOS's memory pressure is normal (green in Activity Monitor),
  every allocation goes through.
- When macOS warns (yellow), QEMU lets the Mac's GPU driver free what it
  still holds for deleted textures, and the app asks the VM to drop its file
  cache (at most every 10 minutes), which Linux then gives back to the Mac.
  Everything still goes through, unless a new big buffer (16 MB or more)
  is bigger than all the memory macOS has left: more swapping is better
  than a black desktop.
- When macOS is critical (red), new big buffers are refused. Before a
  refusal QEMU frees what it can and looks again three times (100 ms).
  Screens, cursors and small buffers are never refused for this, so the
  desktop keeps drawing as long as it can.

Only a runaway VM meets the one fixed guard: all graphics memory together
at most three quarters of the Mac's memory (`OMACVM_GPU_MEMORY_MB` in
QEMU's environment sets another, 0 turns it off; for tests).

**When a buffer is refused**, the app that wanted it loses its GPU context
(the VM's graphics driver cannot hand back an "out of memory" for it). A
browser starts its GPU process again. Hyprland cannot: the VM's Mesa does
not report a lost context, and Hyprland 0.56, when told, stops ("Cannot
continue until proper GPU reset handling is implemented"). The app then
shows "The VM's desktop stopped drawing" with a button that restarts the
desktop session (SDDM logs you in again; apps open in the VM close),
instead of leaving a black window. `logs/qemu.log` says which app lost its
context and why.

**On an 8 GB Mac** the VM gets 4 GB of VM memory by default; with apps
open on a 4K or 5K display the Mac is near its limit. macOS then compresses
and swaps first, and only refuses new graphics when it says memory is
critical. A smaller window or scale 2 needs the least.

**Other VM apps** (what we checked; their own documents may say more):

- **UTM** runs the same QEMU and virglrenderer: graphics memory comes from
  the Mac on top of the VM's memory, with no limit at all.
- **VMware Fusion** has a graphics memory setting of its own
  (`svga.graphicsMemoryKB` in the `.vmx`, 8 GB at most; OmacVM's Fusion route
  sets it), taken from the VM's memory.
- **Parallels Desktop** has a video memory setting (OmacVM's Parallels route
  sets 0, automatic) and draws with the Mac's GPU in its own way; how much
  memory that takes on the Mac it does not say.

Tests: `app/runtime/Tests/virgl/test-resource-budget.c` (build time: the
budget, refusals at critical and warn, the status file, a lost context),
`tests/graphics/fractional-scale.sh` (a running VM).

