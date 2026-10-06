// nativelat DISPLAYID SECONDS: the macOS floor for inputlat.swift. A plain AppKit window on that display
// (layer-backed, as a native app draws) that changes its picture on each key down and each mouse move:
// inputlat measures it like the VM's window (same events, same capture), so the difference is what the
// VM adds. The events are taken in NSApplication.sendEvent, as QEMU takes them (an app in the background
// has no key window). Never takes the focus; quits after SECONDS.
import AppKit

final class Probe: NSView {
  var flip = false
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = (flip ? NSColor.white : NSColor.black).cgColor }
  func toggle() { flip.toggle(); needsDisplay = true }
}

var probe: Probe?
final class App: NSApplication {
  override func sendEvent(_ e: NSEvent) {
    if e.type == .keyDown || e.type == .mouseMoved { probe?.toggle() }
    super.sendEvent(e)
  }
}

let args = CommandLine.arguments
guard args.count == 3, let id = UInt32(args[1]), let secs = Double(args[2]) else {
  FileHandle.standardError.write("usage: nativelat DISPLAYID SECONDS\n".data(using: .utf8)!); exit(2)
}
let app = App.shared
app.setActivationPolicy(.accessory)
guard let screen = NSScreen.screens.first(where: {
  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
}) else { print("no display \(id)"); exit(1) }
let f = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.1, dy: screen.visibleFrame.height * 0.1)
let w = NSWindow(contentRect: f, styleMask: [.titled], backing: .buffered, defer: false, screen: screen)
let v = Probe(frame: NSRect(origin: .zero, size: f.size))
v.wantsLayer = true
w.contentView = v
probe = v
w.orderFrontRegardless()
print("pid \(getpid()) window \(w.windowNumber)"); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + secs) { exit(0) }
app.run()
