import AppKit
import CoreGraphics

/// The VM's keyboard tap. QEMU (a child of this app, so macOS asks about
/// OmacVM) puts an event tap in front of macOS's own key handling, so ⌘ Tab,
/// ⌘ Space and macOS's screenshot keys reach Omarchy while the VM has the
/// keyboard. macOS makes that tap only when OmacVM may read the keyboard
/// (Input Monitoring) or control the computer (Accessibility). Without it
/// QEMU writes "Could not create event tap" into its log and those keys go to
/// macOS instead, and nobody saw that line. Seen on a MacBook (2026-10-06):
/// OmacVM was listed under Accessibility, but for an older signature of the
/// app, which macOS does not count ("Failed to match existing code
/// requirement" in tccd's log), and not listed under Input Monitoring.
enum KeyAccess {
    /// The answers QEMU gets too: both ask for org.omacvm.app (QEMU's
    /// requests count for the app that started it). No prompt.
    static var listen: Bool { CGPreflightListenEventAccess() }
    static var post: Bool { CGPreflightPostEventAccess() }

    /// One line for qemu.log (omacvm check reads it).
    static var record: String {
        "keys: Input Monitoring \(listen ? "allowed" : "NOT allowed"), Accessibility (keys) \(post ? "allowed" : "NOT allowed") for OmacVM"
    }

    /// QEMU's own word from the VM's last start: its tap was refused.
    static func tapFailed(folder: URL) -> Bool {
        // The line comes in QEMU's first second: the log's start is enough.
        guard let h = try? FileHandle(forReadingFrom: folder.appendingPathComponent("logs/qemu.log")) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        return head.range(of: Data("Could not create event tap".utf8)) != nil
    }

    /// Show the note: the last start had no tap, or macOS says neither is allowed.
    static func needsUser(folder: URL) -> Bool { tapFailed(folder: folder) || !(listen || post) }

    static let missingText = "macOS does not let OmacVM read the keyboard, so ⌘ Tab, ⌘ Space and ⌘ ⇧ 4 can go to macOS instead of Omarchy (mostly with the VM in a window). In System Settings › Privacy & Security, turn OmacVM on under Input Monitoring and under Accessibility, then quit the VM and start it again. If OmacVM is already on there, select it, remove it with −, and press Allow… again: macOS still has an older build of the app."

    /// macOS's prompts (each once per app; after that they do nothing) and
    /// the Input Monitoring pane, where OmacVM is then listed.
    static func request() {
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
