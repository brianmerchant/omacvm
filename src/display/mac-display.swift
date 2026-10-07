// Print the built-in display's full-screen area below the notch in pixels,
// with its refresh rate: "3456x2160@120" on a 16" MacBook Pro. A UTM VM pins
// this mode at boot (UTM's GPU path cannot change modes while running).
// With --scale: that display's backing scale instead ("2" on a Retina
// display, "1" on a plain one), the scale a new Fusion VM starts at.
import AppKit
let builtin = NSScreen.screens.first { s in
  (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { CGDisplayIsBuiltin($0) != 0 } ?? false
}
guard let s = builtin ?? NSScreen.main else { exit(1) }
let k = s.backingScaleFactor
if CommandLine.arguments.dropFirst().first == "--scale" {
  print(String(format: "%g", Double(k)))
  exit(0)
}
// Full-screen VM windows start just below the menu bar on a notched display
// (measured: 37 pt on a 16" MacBook Pro, the 38 pt menu bar minus one; macOS's
// own notch-area height says 32). Without a notch they get the whole height.
let menuBar = s.frame.maxY - s.visibleFrame.maxY
let strip = s.auxiliaryTopLeftArea == nil ? 0 : (menuBar > 0 ? menuBar - 1 : 37)
let w = Int(s.frame.width * k), h = Int((s.frame.height - strip) * k)
print("\(w)x\(h)@\(s.maximumFramesPerSecond)")
