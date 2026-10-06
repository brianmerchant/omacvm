-- OmacVM.app: Hyprland draws the pointer (Omarchy's cursor) into the picture;
-- QEMU hides the Mac's over the VM window. Software cursor: virtio-gpu's cursor
-- plane stayed empty here. Written by OmacVM; changes here are overwritten.
hl.config({ cursor = { no_hardware_cursors = 1 } })
-- A config reload brings back the cached mode; apply the window's again.
hl.on("config.reloaded", function()
  hl.exec_cmd("/usr/local/bin/omacvm-display-sync --once")
end)
-- An output that only moves (display-sync, Omanotch, a reload's "auto") sends
-- no event to omacvm-displays, which tells the Mac where the outputs are for
-- the pointer: poke it. At most one poke per 100 ms.
local displays_poke_pending = false
hl.on("monitor.layout_changed", function()
  if displays_poke_pending then return end
  displays_poke_pending = true
  hl.timer(function()
    displays_poke_pending = false
    hl.exec_cmd("/usr/local/bin/omacvm-displays poke")
  end, { timeout = 100, type = "oneshot" })
end)
