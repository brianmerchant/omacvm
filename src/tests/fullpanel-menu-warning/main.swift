import AppKit

@main
struct Tests {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--preference-probe") {
            print(FullPanelMenuWarning.menuBarAlwaysShown())
            return
        }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ text: String) {
            checks += 1
            if !condition() { fatalError("FAIL: \(text)") }
        }
        // A read-only stand-in for Foundation's effective Boolean lookup.
        // No preference database, domains or overrides are changed by tests.
        final class Defaults: UserDefaults, @unchecked Sendable {
            var effective = true
            var keys: [String] = []
            override func bool(forKey key: String) -> Bool {
                keys.append(key)
                return effective
            }
        }
        let defaults = Defaults()
        expect(FullPanelMenuWarning.menuBarAlwaysShown(defaults: defaults), "reads effective NSUserDefaults Boolean")
        defaults.effective = false // System Settings has changed the effective value
        expect(!FullPanelMenuWarning.menuBarAlwaysShown(defaults: defaults), "fresh read sees changed preference")
        expect(defaults.keys == [FullPanelMenuWarning.preference, FullPanelMenuWarning.preference],
               "every attempt rereads exactly QEMU's preference key")
        let warning = FullPanelMenuWarning()
        var resumes: [Bool] = []
        var settings = 0
        var visible = true
        var answer = NSApplication.ModalResponse.alertSecondButtonReturn
        func request(_ fullPanel: Bool = true) -> Bool {
            warning.intercept(wantsFullPanel: fullPanel, visible: { visible }, choose: { answer },
                              settings: { settings += 1; return true }, resume: { resumes.append($0) })
        }
        expect(!request(false), "native/windowed start never intercepted")
        visible = false
        expect(!request(), "FullPanel with menu bar hidden starts normally")
        visible = true
        answer = .alertFirstButtonReturn
        expect(request() && resumes == [true] && !warning.hasPendingStart,
               "standard choice resumes once with a one-start override")
        warning.reactivated()
        expect(resumes == [true], "standard choice never resumes on activation")
        resumes = []
        answer = .alertThirdButtonReturn
        expect(request() && resumes.isEmpty && !warning.hasPendingStart, "Cancel starts nothing")
        answer = .alertSecondButtonReturn
        expect(request() && settings == 1 && resumes.isEmpty && warning.hasPendingStart,
               "Settings leaves one pending start, VM stopped")
        warning.cancel()
        warning.reactivated()
        expect(resumes.isEmpty && !warning.hasPendingStart, "Cancel/quit clears pending startup")

        // Model the launcher's continuation: recheck before starting, for the
        // saved VM (not the VM currently selected in the launcher).
        var currentVM = "A"
        var started: [String] = []
        var choices = 0
        func start(_ vm: String) {
            let intercepted = warning.intercept(wantsFullPanel: true, visible: { visible }, choose: {
                choices += 1
                warning.reactivated() // activation while NSAlert is modal is harmless
                return answer
            }, settings: { settings += 1; return true }, resume: { standard in
                if standard { started.append(vm) } else { start(vm) }
            })
            if !intercepted { started.append(vm) }
        }
        start(currentVM)
        currentVM = "B"
        expect(started.isEmpty && warning.hasPendingStart, "Settings keeps VM A stopped")
        warning.reactivated()
        expect(started.isEmpty && choices == 2 && warning.hasPendingStart,
               "unchanged preference offers choices again, still stopped")
        visible = false
        warning.reactivated()
        expect(started == ["A"] && !warning.hasPendingStart, "corrected preference resumes only VM A")
        warning.reactivated()
        expect(started == ["A"], "pending request consumed, no second start")
        visible = true
        start("A")
        answer = .alertThirdButtonReturn
        warning.reactivated()
        visible = false
        warning.reactivated()
        expect(started == ["A"] && !warning.hasPendingStart, "Cancel after unchanged return prevents later resume")
        answer = .alertSecondButtonReturn
        visible = true
        start("A")
        expect(!request(false) && !warning.hasPendingStart, "new native start replaces pending request")

        var opened: [URL] = []
        expect(FullPanelMenuWarning.openSettings(open: { opened.append($0); return true }), "pane route accepted")
        expect(opened == [FullPanelMenuWarning.settingsURL], "success opens only supported pane route")
        opened = []
        expect(FullPanelMenuWarning.openSettings(open: { opened.append($0); return opened.count == 2 }), "failed link falls back")
        expect(opened == [FullPanelMenuWarning.settingsURL, FullPanelMenuWarning.settingsApp], "fallback opens System Settings app")
        opened = []
        expect(!FullPanelMenuWarning.openSettings(open: { opened.append($0); return false }) && opened.count == 2,
               "both routes failing is bounded")
        var errors = 0
        resumes = []
        expect(warning.intercept(wantsFullPanel: true, visible: { true },
                                 choose: { .alertSecondButtonReturn }, settings: { false },
                                 settingsFailed: {
                                     errors += 1
                                     expect(!warning.hasPendingStart, "pending launch cleared before error")
                                     warning.reactivated()
                                 }, resume: { resumes.append($0) }), "failed Settings open intercepts start")
        expect(errors == 1 && resumes.isEmpty && !warning.hasPendingStart,
               "failed Settings open reports error, leaves VM stopped, clears pending")
        warning.reactivated()
        expect(resumes.isEmpty, "failed Settings open cannot resume on later activation")
        let error = FullPanelMenuWarning.settingsError()
        expect(error.informativeText.contains("Open System Settings manually") &&
               error.informativeText.contains("click Start again") && error.buttons.map(\.title) == ["OK"],
               "Settings failure gives manual steps and explicit restart action")
        let alert = FullPanelMenuWarning.alert()
        expect(alert.buttons.map(\.title) == ["Start in Full Screen Without Notch", "Open Menu Bar Settings…", "Cancel"],
               "three required choices in order")

        let g = NotchGeometry(left: 640, right: 830, strip: 37, width: 1470, height: 956)
        let standard = NotchArea.start(mode: .fullpanel, fullScreen: true, notch: g, guestReady: true, withoutNotch: true)
        expect(!standard.fullPanel && standard.record.contains("Omanotch off"), "override disables FullPanel and records no Omanotch")
        expect(NotchArea.start(mode: .fullpanel, fullScreen: true, notch: g, guestReady: true).fullPanel,
               "next start still selects FullPanel")
        // Warning eligibility must be the existing NotchArea.start decision,
        // including native/windowed/unnotched/unready/invalid geometry cases.
        for mode in NotchMode.allCases {
            for full in [false, true] {
                for ready in [false, true] {
                    for geometry in [nil, g, NotchGeometry(left: 640, right: 830, strip: 4, width: 1470, height: 956)] {
                        let plan = NotchArea.start(mode: mode, fullScreen: full, notch: geometry, guestReady: ready)
                        var offered = false
                        let blocked = warning.intercept(wantsFullPanel: plan.fullPanel, visible: { true }, choose: {
                            offered = true
                            return .alertThirdButtonReturn
                        }, resume: { _ in fatalError("ineligible start resumed") })
                        expect(blocked == plan.fullPanel && offered == plan.fullPanel,
                               "warning follows existing eligibility: \(mode) full=\(full) ready=\(ready) geometry=\(String(describing: geometry))")
                    }
                }
            }
        }
        expect(!NotchArea.start(mode: .fullpanel, fullScreen: true, notch: g, guestReady: true, withoutNotch: true).fullPanel,
               "one-start standard override remains ineligible for warning")
        print("fullpanel-menu-warning: \(checks) checks passed")
    }
}
