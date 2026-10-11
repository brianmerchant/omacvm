import AppKit

/// A single launcher-owned start waiting for the person in System Settings.
/// No preference overrides: QEMU keeps its own FullPanel fallback guard.
@MainActor
final class FullPanelMenuWarning {
    private var pending: (() -> Void)?
    private var asking = false
    var hasPendingStart: Bool { pending != nil }

    static let preference = "AppleMenuBarVisibleInFullscreen"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    static let settingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    /// QEMU uses standardUserDefaults.boolForKey, including its search order
    /// and Boolean conversion. Foundation observes external defaults changes;
    /// read again on every attempt (including reactivation), never cache or
    /// synchronize/write a preferences domain ourselves.
    static func menuBarAlwaysShown(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: preference)
    }

    static func alert() -> NSAlert {
        let a = NSAlert()
        a.messageText = "FullPanel needs the menu bar to hide in full screen"
        a.informativeText = "macOS is set to always show the menu bar in full screen. It would cover the strip beside the camera notch that FullPanel uses.\n\nStart in full screen without the notch this time, or open Menu Bar settings and choose to hide the menu bar in full screen. Return to OmacVM to continue. Your VM's selected FullPanel mode stays unchanged."
        a.addButton(withTitle: "Start in Full Screen Without Notch")
        a.addButton(withTitle: "Open Menu Bar Settings…")
        a.addButton(withTitle: "Cancel")
        a.buttons.last?.keyEquivalent = "\u{1b}"
        return a
    }

    static func settingsError() -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Could not open Menu Bar settings"
        a.informativeText = "The VM has not started. Open System Settings manually and find Menu Bar (under Control Center on older macOS). Choose to hide the menu bar in full screen, then return to OmacVM and click Start again. You can also choose Start in Full Screen Without Notch."
        a.addButton(withTitle: "OK")
        return a
    }

    /// A rejected pane URL opens System Settings itself instead. No UI scripting.
    @discardableResult
    static func openSettings(open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        open(settingsURL) || open(settingsApp)
    }

    func cancel() { pending = nil }

    /// Consume before resuming: activation during a modal alert cannot start twice.
    func reactivated() {
        guard !asking, let resume = pending else { return }
        pending = nil
        resume()
    }

    /// true: stop this invocation. The continuation carries only this VM request;
    /// true in the continuation means standard full screen for this start only.
    func intercept(wantsFullPanel: Bool,
                   visible: @MainActor () -> Bool = { FullPanelMenuWarning.menuBarAlwaysShown() },
                   choose: @MainActor () -> NSApplication.ModalResponse = {
                       NSApp.activate()
                       return FullPanelMenuWarning.alert().runModal()
                   },
                   settings: @MainActor () -> Bool = { FullPanelMenuWarning.openSettings() },
                   settingsFailed: @MainActor () -> Void = {
                       NSApp.activate()
                       FullPanelMenuWarning.settingsError().runModal()
                   },
                   resume: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard !asking else { return true }
        cancel()
        guard wantsFullPanel && visible() else { return false }
        asking = true
        let answer = choose()
        asking = false
        switch answer {
        case .alertFirstButtonReturn:
            resume(true)
        case .alertSecondButtonReturn:
            pending = { resume(false) }
            if !settings() {
                cancel()
                asking = true
                settingsFailed()
                asking = false
            }
        default:
            cancel()
        }
        return true
    }
}
