import Foundation

/// "Use the notch for the menu bar": full screen also covers the strip beside
/// the notch and Omarchy's bar goes there. That full screen has no Space of
/// its own (macOS keeps full-screen Spaces below the notch).
///
/// The rules on their own (Foundation only), so src/tests/app-notch.sh can
/// compile and test them without the app.
enum NotchSetting {
    /// The settings key; `omacvm check` reads it too.
    static let key = "useNotch"

    /// The user's choice: on unless they switched it off. Never touching the
    /// switch counts as on, also for VMs made when the default was off.
    static func choice(stored: Any?) -> Bool {
        stored as? Bool ?? true
    }

    /// What the VM gets: the choice, and only on a Mac whose built-in display
    /// has a notch. Without one it is off whatever was stored.
    static func active(choice: Bool, hasNotch: Bool) -> Bool {
        choice && hasNotch
    }
}
