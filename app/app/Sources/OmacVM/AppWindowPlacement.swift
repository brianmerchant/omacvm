import AppKit

extension NSWindow {
    /// The app's own window: centred on the built-in display, else the main
    /// one (WindowPlacement.appScreen). Not NSWindow.center(): that picks the
    /// active menu bar's display (the external one, often) and sits above the
    /// middle. The app sets no frame autosave name and no restoration, so
    /// nothing brings back an old place on another display.
    /// Main thread. src/tests/app-window-real.sh runs it on real displays.
    func centreOnAppScreen() {
        func id(_ s: NSScreen) -> UInt32? {
            s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        }
        let screens = NSScreen.screens.compactMap { s in id(s).map { WindowPlacement.Screen(id: $0, frame: s.visibleFrame) } }
        let builtIn = screens.first { CGDisplayIsBuiltin($0.id) != 0 }?.id
        guard let s = WindowPlacement.appScreen(screens: screens, builtIn: builtIn, main: NSScreen.main.flatMap(id)) else { return }
        // SwiftUI sizes the window from its content: lay it out first.
        contentView?.layoutSubtreeIfNeeded()
        var size = frame.size
        if size.width < 1 || size.height < 1, let v = contentView {
            size = frameRect(forContentRect: NSRect(origin: .zero, size: v.fittingSize)).size
        }
        setFrameOrigin(WindowPlacement.centred(size, in: s.frame))
    }
}
