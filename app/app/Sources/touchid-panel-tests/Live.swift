// touchid-panel-tests --show OUT.txt: the panel on a real screen in Tokyo
// Night, Flexoki Light and a rounded gradient theme, 4 s each, for
// screenshots (a line with its window id in OUT.txt as each shows). touchid-panel-tests --live OUT.json: the
// panel's timing on a real screen,
// with a stand-in that ends each evaluation on cue instead of a finger (no
// LocalAuthentication, nothing asks). Needs a logged-in GUI session (a test
// Mac, never in CI): a plain window plays the VM's, the panel shows over it.
// For each end it measures, from the moment the "finger" is done: when the
// answer goes out, when the person's input is back with the VM (QEMU's
// didClose hook), and when the panel is off the screen (CGWindowList, our
// own windows at the panel's level). Also how long the panel takes to show.
import AppKit
import Foundation
@testable import OmacVMTouchIDPanel
import OmacVMAuth

func uptime() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

/// Ends the evaluation `after` seconds in, with `end`.
final class CueEvaluator: PanelEvaluator {
    let end: PanelLAEnd, after: TimeInterval
    private(set) var endedAt: Double?
    private var dead = false
    init(_ end: PanelLAEnd, after: TimeInterval) { self.end = end; self.after = after }
    func unavailable() -> PanelLAEnd? { nil }
    var view: NSView? { nil }
    func evaluate(reason: String, _ done: @escaping (PanelLAEnd) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [self] in
            guard !dead else { return }
            endedAt = uptime()
            done(end)
        }
    }
    func invalidate() { dead = true }
}

/// Watches whether one of our windows at the panel's level is on screen.
final class PanelWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false, firstOn: Double?, lastOff: Double?
    private var running = true
    init() {
        let pid = getpid()
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                let now = list.contains { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 28 }
                let t = uptime()
                lock.withLock {
                    if now && !on && firstOn == nil { firstOn = t }
                    if !now && on { lastOff = t }
                    on = now
                }
                usleep(2000)
            }
        }
    }
    func reset() { lock.withLock { firstOn = nil; lastOff = nil } }
    var shownAt: Double? { lock.withLock { firstOn } }
    var goneAt: Double? { lock.withLock { on ? nil : lastOff } }
    func stop() { lock.withLock { running = false } }
}

/// The VM's stand-in window and the app made active (show() asks for that).
func liveApp() -> NSApplication {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let vm = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 960, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
    vm.title = "touchid-panel-tests live (the VM's window)"
    vm.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    return app
}

func runShow(_ out: String) -> Never {
    let app = liveApp()
    FileManager.default.createFile(atPath: out, contents: nil)
    let log = FileHandle(forWritingAtPath: out)
    let themes: [(String, [String: Any])] = [
        ("tokyo-night", ["background": "#1a1b26", "foreground": "#a9b1d6", "accent": "#7aa2f7", "error": "#f7768e", "success": "#9ece6a",
                         "border": ["#7aa2f7"], "radius": 0]),
        ("flexoki-light", ["background": "#fffcf0", "foreground": "#100f0f", "accent": "#205ea6", "error": "#d14d41", "success": "#879a39",
                           "border": ["#205ea6"], "radius": 0]),
        ("rounded-gradient", ["background": "#101315", "foreground": "#cacccc", "accent": "#7aa2f7", "error": "#f7768e", "success": "#9ece6a",
                              "border": ["#33ccff", "#00ff99"], "border_angle": 45, "radius": 10]),
    ]
    let controller = PanelController(evaluator: { CueEvaluator(.cancelled, after: 3600) })
    var i = 0
    func next() {
        guard i < themes.count else { exit(0) }
        guard app.isActive else { app.activate(ignoringOtherApps: true); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }; return }
        let (name, theme) = themes[i]
        i += 1
        let p = TouchIDPanelPrompt.parse(["title": "Touch ID in Omarchy", "line": "sudo in pts/1 wants to run", "box": "pacman -Syu",
                                          "timeout": 30, "theme": theme] as [String: Any])!
        controller.show(p) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let id = list.first { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int) == 28 }?[kCGWindowNumber as String]
            log?.write(Data("show \(name) window \(id.map { "\($0)" } ?? "none")\n".utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { controller.cancel(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
    app.run()
    exit(1)
}

func runLive(_ out: String) -> Never {
    let app = liveApp()
    let watch = PanelWatch()
    let prompt = TouchIDPanelPrompt(title: "Touch ID in Omarchy", line: "sudo in pts/1 wants to run", box: "pacman -Syu", timeout: 30, colors: [:])
    // (end, reduce motion), 5 runs each.
    let plan: [(PanelLAEnd, Bool)] = Array(repeating: [(PanelLAEnd.yes, false), (.failed, false), (.cancelled, false), (.yes, true)], count: 5)
        .flatMap { $0 }
    var results: [[String: Any]] = []
    var i = 0
    var current: CueEvaluator?
    var reduce = false
    var inputBack: Double?
    let controller = PanelController(evaluator: { current! }, reduceMotion: { reduce })
    controller.didClose = { inputBack = uptime() }
    func ms(_ a: Double?, _ b: Double?) -> Any { guard let a, let b else { return NSNull() }; return ((a - b) * 10000).rounded() / 10 }
    func next() {
        guard i < plan.count else {
            watch.stop()
            let o: [String: Any] = ["runs": results, "note": "ms after the stand-in's end; shown_ms after show()"]
            try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: out))
            print("live: \(results.count) runs -> \(out)")
            exit(0)
        }
        let (end, rm) = plan[i]
        i += 1
        guard app.isActive else {
            app.activate(ignoringOtherApps: true)
            i -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() }
            return
        }
        reduce = rm
        inputBack = nil
        watch.reset()
        let e = CueEvaluator(end, after: 0.8)
        current = e
        var answered: Double?
        let asked = uptime()
        controller.show(prompt) { _ in answered = uptime() }
        // Long enough for every end to play out (3.0.3's slowest closed at 1.6 s).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            results.append(["end": "\(end)", "reduce_motion": rm, "shown_ms": ms(watch.shownAt, asked),
                            "answer_ms": ms(answered, e.endedAt), "input_back_ms": ms(inputBack, e.endedAt),
                            "off_screen_ms": ms(watch.goneAt, e.endedAt)])
            print("live: \(results.last!)")
            next()
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
    app.run()
    exit(1)
}
