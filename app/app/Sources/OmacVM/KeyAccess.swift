import AppKit
import CoreGraphics

/// The VM's keyboard tap. QEMU (a child of this app, so macOS asks about
/// OmacVM) puts an event tap in front of macOS's own key handling, so ⌘ Tab,
/// ⌘ Space and macOS's screenshot keys reach Omarchy while the VM has the
/// keyboard. It is an active tap at the HID level (ui/cocoa.m:
/// kCGHIDEventTap, kCGEventTapOptionDefault: it swallows the keys), and macOS
/// makes that only for an app allowed to control the computer
/// (CGPreflightPostEventAccess, listed under Accessibility). Input Monitoring
/// covers listen-only taps and does not count; AXIsProcessTrusted is a
/// separate answer too (#211). Without it QEMU writes "Could not create event
/// tap" into its log and those keys go to macOS instead. Seen on a MacBook
/// (2026-10-07): Input Monitoring on, "control the computer" off, tap refused;
/// the window's Allow… opened Input Monitoring, and the note stayed red.
enum KeyAccess {
    /// The answers QEMU gets too: both ask for org.omacvm.app (QEMU's
    /// requests count for the app that started it). No prompt.
    static var listen: Bool { CGPreflightListenEventAccess() }
    static var post: Bool { CGPreflightPostEventAccess() }

    /// What QEMU's tap needs, and all the window checks.
    static var allowed: Bool { post }

    /// One line for qemu.log (KeyNote and omacvm check read it). Input
    /// Monitoring only for the record.
    static var record: String {
        "keys: Input Monitoring \(listen ? "allowed" : "NOT allowed"), Accessibility (keys) \(post ? "allowed" : "NOT allowed") for OmacVM"
    }

    /// The head of qemu.log of the VM's last start: macOS's answer recorded
    /// then (`record`) and QEMU's "Could not create event tap" both come in
    /// QEMU's first second.
    static func lastLog(folder: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent("logs/qemu.log")) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        return String(decoding: head, as: UTF8.self)
    }

    /// QEMU's own word from the VM's last start: its tap was refused.
    static func tapFailed(folder: URL) -> Bool {
        lastLog(folder: folder)?.contains("Could not create event tap") == true
    }

    /// The window's line: the one setting.
    static let shortText = "Allow OmacVM under Accessibility"

    /// Behind the (i): the steps.
    static var missingText: String {
        let app = (Bundle.main.bundlePath as NSString).abbreviatingWithTildeInPath
        return "Without it, ⌘ Tab, ⌘ Space and ⌘ ⇧ 4 go to macOS instead of Omarchy. Input Monitoring is not enough.\n\n1. Allow… opens System Settings › Privacy & Security › Accessibility.\n2. An OmacVM there already (an older build that macOS no longer counts): select it and remove it with −.\n3. Add \(app) with + and turn it on.\n4. Quit the VM and start it again."
    }

    /// macOS's prompt for "control the computer" (once per app; after that
    /// it does nothing; it also lists OmacVM under Accessibility) and the
    /// Accessibility pane.
    static func request() {
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
