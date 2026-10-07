// "Restart the Desktop…" after Later, the graphics memory file and what the app
// says about a lost GPU context (OmacVMDesktop), without a VM:
//   cd app/app && swift run desktop-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMDesktop

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

let logs = FileManager.default.temporaryDirectory
    .appendingPathComponent("omacvm-desktop-tests-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: logs)
try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: logs) }
let d = DesktopRestart(logs: logs, bundleID: "org.omacvm.app.test", pid: 4242)

expect(d.lost.lastPathComponent == "desktop-lost", "the file name QEMU's patch is given")
expect(d.requestName == "org.omacvm.app.test.desktop-restart.4242", "request name: bundle id and pid")
expect(DesktopRestart(logs: logs, bundleID: nil, pid: 7).requestName == "org.omacvm.app.desktop-restart.7",
       "no bundle id: the release id")
expect(d.requestName != DesktopRestart(logs: logs, bundleID: "org.omacvm.app.test", pid: 4243).requestName,
       "another running app (another VM) has another name")
expect(d.requestName.hasSuffix(".4242") && !d.requestName.contains("features"), "not the Features… name")

expect(!d.isLost && !d.takesRequest(), "a new VM: no menu item, a click does nothing")

// Later, then the menu item.
expect(d.markLost("Hyprland lost its GPU context; Later"), "Later writes desktop-lost")
expect(d.isLost && d.takesRequest(), "the menu item shows and a click counts")
expect((try? String(contentsOf: d.lost, encoding: .utf8)) == "Hyprland lost its GPU context; Later\n", "with why in it")
expect(d.markLost("again") && d.isLost, "a second Later keeps it")

// Restart the Desktop, or the VM starts or stops.
d.clear()
expect(!d.isLost && !d.takesRequest(), "clear: no menu item, a late click does nothing")
d.clear()
expect(!d.isLost, "clear twice is fine")

// A folder where the file should be is not "lost" (QEMU checks a plain file too).
try FileManager.default.createDirectory(at: d.lost, withIntermediateDirectories: false)
expect(!d.isLost, "a folder named desktop-lost does not count")
try? FileManager.default.removeItem(at: d.lost)

// No logs folder (the VM folder went away): nothing breaks.
let gone = DesktopRestart(logs: logs.appendingPathComponent("missing"), bundleID: nil, pid: 1)
expect(!gone.markLost("x") && !gone.isLost, "a missing logs folder: false, no crash")
gone.clear()

// QEMU's logs/gpu-memory (GPUMemory): the desktop reserve and why contexts were lost
// (virgl-gpu-guard-desktop-reserve.patch).
let status = """
    in_use_mb=6100
    peak_mb=6144
    budget_mb=6144
    pressure=normal
    refused=3
    lost=3
    lost_last=chromium
    lost_recent=quickshell,Hyprland,chromium
    apps_mb=5632
    reserve_mb=512
    lost_why=guard
    lost_recent_why=error,guard,guard

    """
let gm = GPUMemory.parse(status)
expect(gm?.appsMB == 5632 && gm?.reserveMB == 512 && gm?.budgetMB == 6144, "apps_mb, reserve_mb, budget_mb read")
expect(gm?.lostRecentWhy == ["error", "guard", "guard"], "lost_recent_why read")
expect(gm?.why(of: DesktopRecovery.compositors) == "guard", "why Hyprland was lost: guard")
expect(gm?.why(of: DesktopRecovery.shells) == "error", "why quickshell was lost: error")
expect(gm?.why(of: ["firefox"]) == nil, "a context not lost: nil")
expect(gm?.lostReason == "Its graphics reached the most one VM may use on this Mac (6.0 GB, even with the 512 MB kept for the desktop).",
       "the alert names the budget and the desktop's part")
var gp = gm!
gp.lostRecentWhy = ["error", "pressure", "guard"]
expect(gp.lostReason == "macOS ran short of memory for its graphics.", "lost for pressure: macOS short of memory")
gp.lostRecentWhy = ["error", "error", "guard"]
expect(gp.lostReason == "Its graphics on the Mac failed.", "lost for another reason: failed, even at the budget")
expect(DesktopRecovery.reason(why: "guard", pressure: "normal", refused: 3) == "guard", "the VM's note: guard")
expect(DesktopRecovery.reason(why: "pressure", pressure: "normal", refused: 0) == "memory", "pressure: memory")
expect(DesktopRecovery.reason(why: "error", pressure: "critical", refused: 9) == "graphics", "error: graphics, whatever else")
expect(DesktopRecovery.reason(why: nil, pressure: "normal", refused: 0) == "graphics", "older runtime, nothing refused: graphics")
expect(DesktopRecovery.reason(why: nil, pressure: "warn", refused: 0) == "memory", "older runtime, pressure: memory")
// An older runtime: no apps_mb, reserve_mb or why; the old guesses.
let old = GPUMemory.parse("in_use_mb=6000\nbudget_mb=6144\npressure=normal\nrefused=3\nlost=1\nlost_recent=Hyprland\n")
expect(old?.why(of: DesktopRecovery.compositors) == nil && old?.reserveMB == 0, "older runtime: no why, no reserve")
expect(old?.lostReason == "Its graphics reached the most one VM may use on this Mac (6.0 GB).", "older runtime at the budget: the budget")
var older = old!
older.inUseMB = 2000
expect(older.lostReason == "macOS ran short of memory for its graphics.", "older runtime, refused below the budget: macOS")
older.refused = 0
expect(older.lostReason == "Its graphics on the Mac failed.", "older runtime, nothing refused: failed")
// Lists of different length (a reader between two writes cannot get that, but): no why.
var odd = gm!
odd.lostRecentWhy = ["guard"]
expect(odd.why(of: DesktopRecovery.compositors) == nil, "why list of another length: not trusted")
expect(GPUMemory.parse("pressure=normal\n") == nil, "no in_use_mb: not a status file")

// Which apps the VM tells about (GPUMemoryNotice).
let now = Date()
let told = GPUMemoryNotice.apps(lost: ["chromium", "Hyprland", "quickshell", "firefox", "chromium", "mpv"],
                                why: ["guard", "guard", "pressure", "pressure", "guard", "error"],
                                lastTold: [:], now: now)
expect(told.map { "\($0.name):\($0.why)" } == ["chromium:guard", "firefox:pressure"],
       "apps lost to the guard or pressure, once each; not the desktop, the shell or another error")
expect(GPUMemoryNotice.apps(lost: ["chromium"], why: ["guard"], lastTold: ["chromium": now.addingTimeInterval(-30)], now: now).isEmpty,
       "told 30 s ago: not again")
expect(GPUMemoryNotice.apps(lost: ["chromium"], why: ["guard"], lastTold: ["chromium": now.addingTimeInterval(-90)], now: now).count == 1,
       "told 90 s ago: again")
expect(GPUMemoryNotice.apps(lost: ["chromium"], why: [], lastTold: [:], now: now).isEmpty, "an older runtime (no why): nothing")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("desktop restart and graphics memory: all checks passed")
