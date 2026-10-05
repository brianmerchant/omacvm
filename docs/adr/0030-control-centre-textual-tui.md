# 0030: The control centre is a Textual TUI

Status: accepted, built (round 1). Branch `control-centre`.

## Context

`omacvm` inside Omarchy opens the OmacVM control centre: features on/off,
repair, updates, details, report a problem. It should look and feel like
Omarchy's own TUIs (Impala, bluetui, Wiremix: ratatui, terminal colours,
keys at the bottom), open in under 0.5 s, follow the theme, and stay easy to
change in a repo that is mostly bash and Swift and copies `src/` into the VM
on every `omacvm apply`.

## Options

1. Rust + ratatui, like Impala and bluetui. Best fit in look and speed, but a
   compiled binary: a Rust toolchain in the VM (minutes per update) or a
   prebuilt asset per release (CI, signing, a binary outside pacman).
2. Go + bubbletea. Same binary problem; Charm's look is gum's, which Omarchy
   uses only in its installer.
3. Python 3 + Textual (`python-textual` 8.2.8 in Arch Linux ARM's repo).
   No build step, ships as source with the rest of `src/`, a headless test
   driver (Pilot) for UI tests, ANSI-colour mode so the terminal's (Omarchy's)
   palette applies.
4. bash + gum. No live multi-screen UI (status updating while a job runs).

## Decision

Option 3. Measured on the M4 Max: Textual imports in 0.10 s and draws a
12-row table in 0.12 s. The first frame uses local files only; the guest
check and the Mac answers fill in afterwards.

## Consequences

- One package (and its Python dependencies) more in the VM, from pacman, so
  `omarchy update` keeps it current.
- If Textual is missing or broken, `omacvm` prints the same table as plain
  text with the commands to use: never an empty window.
- Startup in a Parallels VM on the M4 Max, in a pty, to the first full table:
  0.36 s with cold caches, 0.20-0.23 s after. Still to measure on an M1 with
  8 GB (budget 0.5 s).
- Status glyphs are Nerd Font glyphs in theme colours, not emoji: ⚠️ with
  VS16 has different widths in Alacritty, Ghostty and Kitty and breaks the
  columns.
