import Foundation

/// "Escape combo" (Ctrl+Option+Cmd+Esc in a full-screen VM): swipe only the
/// monitor under the pointer between the VM and macOS (the default), or all
/// monitors that show the VM. OmacVM Gestures does the swipe and reads this
/// from its own settings domain, so `defaults write org.omacvm.gestures
/// EscapeSwipe all` sets it for the other routes (Parallels, UTM, Fusion) too.
///
/// The rules on their own (Foundation only): src/tests/app-escape-window.sh
/// compiles and tests them without the app.
enum EscapeSetting {
    static let domain = "org.omacvm.gestures"
    static let key = "EscapeSwipe"

    enum Choice: String, CaseIterable {
        case pointer, all
        var title: String {
            switch self {
            case .pointer: "Swipe the monitor under the pointer"
            case .all: "Swipe all monitors"
            }
        }
    }

    /// What Gestures does with a stored value: "all" (any case) swipes all
    /// monitors, anything else the one under the pointer.
    static func choice(stored: Any?) -> Choice {
        (stored as? String)?.lowercased() == Choice.all.rawValue ? .all : .pointer
    }

    static func current(_ d: UserDefaults? = UserDefaults(suiteName: domain)) -> Choice {
        choice(stored: d?.object(forKey: key))
    }

    static func set(_ c: Choice, _ d: UserDefaults? = UserDefaults(suiteName: domain)) {
        d?.set(c.rawValue, forKey: key)
    }
}
