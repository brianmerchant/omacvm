import AppKit
import Foundation

/// The VM's graphics memory on the Mac: textures and buffers its apps draw
/// with. It comes from the Mac's memory as the VM needs it, on top of the VM's
/// own memory. QEMU writes it to logs/gpu-memory (virgl-darwin-memory-pressure.patch):
/// in use now, the peak since the VM started, macOS's memory pressure, how many
/// allocations were refused and which GPU context was lost last.
struct GPUMemory: Equatable {
    var inUseMB = 0
    var peakMB = 0
    var budgetMB = 0
    var pressure = "normal"
    var refused = 0
    var lost = 0
    var lostLast = ""
    /// The last eight lost contexts, oldest first.
    var lostRecent: [String] = []

    static func file(for config: VMConfig) -> URL {
        config.folder.appendingPathComponent("logs/gpu-memory")
    }

    static func read(for config: VMConfig) -> GPUMemory? {
        guard let text = try? String(contentsOf: file(for: config), encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> GPUMemory? {
        var m = GPUMemory()
        var seen = false
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let n = Int(kv[1]) ?? 0
            switch kv[0] {
            case "in_use_mb": m.inUseMB = n; seen = true
            case "peak_mb": m.peakMB = n
            case "budget_mb": m.budgetMB = n
            case "pressure": m.pressure = kv[1]
            case "refused": m.refused = n
            case "lost": m.lost = n
            case "lost_last": m.lostLast = kv[1]
            case "lost_recent": m.lostRecent = kv[1].split(separator: ",").map(String.init)
            default: break
            }
        }
        return seen ? m : nil
    }

    static func gb(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
    }

    /// "Graphics memory: 1.6 GB (peak 2.6 GB)"
    var line: String { "Graphics memory: \(GPUMemory.gb(inUseMB)) (peak \(GPUMemory.gb(peakMB)))" }

    static let explanation = """
        VM memory is the Mac memory the VM gets as its RAM (set above). Graphics memory \
        is extra: the textures and buffers the VM's desktop and apps draw with, taken \
        from the Mac's memory as they need it (a 5K desktop with a browser: about 2 GB). \
        There is no fixed limit; only when macOS itself runs short are new big ones refused.
        """
}

/// While a VM runs: follows its graphics memory and macOS's memory pressure.
/// - When macOS warns that memory is short, the VM is asked to drop its file
///   cache (at most every 10 minutes): Linux then reports the pages free and
///   the Mac gets them back (virtio-balloon free page reporting).
/// - When the desktop's GPU context is lost (the VM would stay black), the
///   desktop session starts again by itself, or a window says so and offers
///   to restart it (DesktopRecovery says which).
@MainActor
final class GPUMemoryWatch {
    private let config: VMConfig
    private let log: (String) -> Void
    private var timer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    private var lastTrim = Date.distantPast
    private var trimming = false
    private var lostSeen = 0
    private var alert: NSAlert?
    private var lastDesktopRestart: Date?
    private var lastShellRestart: Date?

    init(config: VMConfig, log: @escaping (String) -> Void) {
        self.config = config
        self.log = log
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let event = source.data
            Task { @MainActor in self?.macOSShort(critical: event.contains(.critical)) }
        }
        source.resume()
        pressure = source
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pressure?.cancel()
        pressure = nil
        if let w = alert?.window, w.isVisible { NSApp.abortModal(); w.orderOut(nil) }
    }

    private func macOSShort(critical: Bool) {
        guard !trimming, Date().timeIntervalSince(lastTrim) > 600 else { return }
        trimming = true
        let socket = config.agentSocket.path
        let level = critical ? "critical" : "warning"
        log("OmacVM: macOS memory pressure \(level): asking the VM to drop its file cache")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = GuestAgent.run(socketPath: socket, "/bin/sh", ["-c", "sync; echo 1 > /proc/sys/vm/drop_caches"])
            Task { @MainActor in self?.trimmed(ok) }
        }
    }

    /// Done once per 10 minutes when the VM did it; when its agent did not
    /// answer (still starting, busy), tried again in 30 seconds.
    private func trimmed(_ ok: Bool) {
        trimming = false
        if ok {
            lastTrim = Date()
            log("OmacVM: the VM dropped its file cache")
        } else {
            lastTrim = Date().addingTimeInterval(-600 + 30)
            log("OmacVM: the VM's agent did not answer: trying again in 30 s")
        }
    }

    private func poll() {
        guard let m = GPUMemory.read(for: config) else { return }
        // macOS tells only some processes about a warning, one at a time; QEMU
        // also looks for itself once a second and writes what it sees.
        if m.pressure != "normal" { macOSShort(critical: m.pressure == "critical") }
        if m.lost > lostSeen {
            // Several can be lost between two looks (the desktop, then a browser).
            let new = m.lostRecent.suffix(min(m.lost - lostSeen, m.lostRecent.count))
            lostSeen = m.lost
            lost(Array(new), m)
        }
    }

    private func lost(_ names: [String], _ m: GPUMemory) {
        guard alert == nil else { return }
        let now = Date()
        let action = DesktopRecovery.action(lost: names, enabled: DesktopRecovery.enabled(),
                                            lastDesktop: lastDesktopRestart, lastShell: lastShellRestart, now: now)
        switch action {
        case .none:
            return
        case .restartShell:
            lastShellRestart = now
            log("OmacVM: the VM's shell (Quickshell) lost its GPU context: restarting the shell by itself")
            guest("/usr/local/bin/omacvm-desktop-recover", ["shell"]) { _ in }
        case .restartDesktop:
            lastDesktopRestart = now
            log("OmacVM: the VM's desktop (Hyprland) lost its GPU context; \(m.line), pressure \(m.pressure), \(m.refused) refused")
            log("OmacVM: restarting the VM's desktop by itself: apps open in the VM close (once per 10 min, else the app asks)")
            let why = DesktopRecovery.reason(pressure: m.pressure, refused: m.refused)
            guest("/usr/local/bin/omacvm-desktop-recover", ["desktop", why]) { [weak self] ok in
                guard let self, !ok else { return }
                self.log("OmacVM: the VM's agent did not restart the desktop: asking")
                self.desktopLost(m, again: false)
            }
        case .ask(let again):
            log("OmacVM: the VM's desktop (Hyprland) lost its GPU context; \(m.line), pressure \(m.pressure), \(m.refused) refused")
            desktopLost(m, again: again)
        }
    }

    /// Runs a program in the VM off the main thread. A VM set up before
    /// omacvm-desktop-recover (3.0.0) has no such program (the agent refuses):
    /// the login manager is restarted directly there (no note in the new
    /// session). Not when the agent did not answer: the restart may be under
    /// way, and a second one would end the new session too.
    private func guest(_ path: String, _ args: [String], done: @escaping @MainActor (Bool) -> Void) {
        let socket = config.agentSocket.path
        DispatchQueue.global(qos: .userInitiated).async {
            var result = GuestAgent.start(socketPath: socket, path, args)
            if result == .refused, args.first == "desktop" {
                result = GuestAgent.start(socketPath: socket, "/usr/bin/systemctl", ["restart", "sddm"])
            }
            let ok = result == .started
            Task { @MainActor in done(ok) }
        }
    }

    /// The compositor is not told about a lost context: the VM's Mesa does not
    /// report resets, and Hyprland 0.56 would only stop ("Cannot continue until
    /// proper GPU reset handling is implemented") if it were. Asked when the
    /// automatic restart is off, did not work, or was done shortly before.
    private func desktopLost(_ m: GPUMemory, again: Bool) {
        guard alert == nil else { return }
        let a = NSAlert()
        a.messageText = again ? "The VM's desktop stopped drawing again" : "The VM's desktop stopped drawing"
        a.informativeText = (again ? "It was restarted a few minutes ago. " : "") +
            (DesktopRecovery.reason(pressure: m.pressure, refused: m.refused) == "graphics"
            ? "Its graphics on the Mac failed. "
            : "macOS ran short of memory for its graphics. ") +
            "The VM still runs, but its screen stays black until the desktop starts again. " +
            "Restarting the desktop closes the apps open in the VM; anything not saved in them is lost."
        a.addButton(withTitle: "Restart the Desktop")
        a.addButton(withTitle: "Later")
        a.window.level = .floating
        a.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert = a
        NSApp.activate()
        let answer = a.runModal()
        alert = nil
        guard answer == .alertFirstButtonReturn else {
            log("OmacVM: the desktop stays black for now (Later)")
            return
        }
        log("OmacVM: restarting the VM's desktop session")
        // Counts as a restart: lost again soon after, the app asks again.
        lastDesktopRestart = Date()
        // The login manager starts again and logs the user in again (SDDM's
        // autologin), or shows its login screen.
        guest("/usr/local/bin/omacvm-desktop-recover", ["desktop", DesktopRecovery.reason(pressure: m.pressure, refused: m.refused)]) { _ in }
    }
}
