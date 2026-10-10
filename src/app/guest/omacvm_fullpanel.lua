-- Select the boot's bar synchronously while config loads, before Omarchy's
-- hyprland.start callback launches its shell. Reloads are harmless; a live
-- shell is never restarted or switched behind its back. Failures go to the
-- compositor log and leave the working selection in place.
os.execute("/usr/local/bin/omacvm-fullpanel prepare")
