import CoreGraphics

/// Where a VM's window opens: on the display the user is using, the one under
/// the pointer, else the one with the active menu bar (where the Start button
/// was clicked). With one display there is nothing to choose: QEMU's own
/// frame. QEMU puts its main window on the display it is given and keeps it
/// there (full screen goes to that display too).
///
/// Core Graphics only: src/tests/app-escape-window.sh tests it without the app.
enum WindowPlacement {
    struct Screen: Equatable {
        let id: UInt32
        let frame: CGRect   // AppKit's coordinates, as NSScreen and NSEvent.mouseLocation give them
    }

    static func display(pointer: CGPoint, screens: [Screen], menuBar: UInt32?) -> UInt32? {
        guard screens.count > 1 else { return nil }
        if let s = screens.first(where: { $0.frame.contains(pointer) }) { return s.id }
        return screens.contains { $0.id == menuBar } ? menuBar : nil
    }
}
