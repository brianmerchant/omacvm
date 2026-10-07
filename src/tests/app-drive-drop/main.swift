// OmacVM.app's DriveWatch (app/app/Sources/OmacVM/DriveWatch.swift) against a
// real disk image that goes away under it; run by src/tests/app-drive-drop.sh.
// Arguments: WORK (an empty folder on the Mac's own disk), MOUNT (where the
// image is mounted), IMAGE (the image file, attached again for the second
// drop), NAME (its volume name); optional RENAME (see the rename check).
import AppKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let work = URL(fileURLWithPath: args[1]), mount = URL(fileURLWithPath: args[2])
let image = args[3], volumeName = args[4]
let fm = FileManager.default
var failed = 0

func expect(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) \(detail())"); failed += 1 }
}

func hdiutil(_ a: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    p.arguments = a
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice   // detach -force: "deprecated" warning
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// Runs the main run loop (the watch calls back on the main queue) until
/// `done` or SECONDS passed.
func wait(_ seconds: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}

// mounted: by device, from the mount table.
let here = work.appendingPathComponent("here")
try fm.createDirectory(at: here, withIntermediateDirectories: true)
let dev = Storage.device(here)!
expect("mounted: the Mac's disk", DriveWatch.mounted(dev))
expect("mounted: the image", DriveWatch.mounted(Storage.device(mount)!))
expect("mounted: no such device", !DriveWatch.mounted(-12345))

// A VM folder on the Mac's own disk: no signal; stop() ends it quietly.
var calls: [String] = []
let local = DriveWatch(folder: here) { calls.append($0) }
expect("a folder on the Mac's disk is watched", local != nil)
wait(2.5) { false }
local?.stop()
expect("no signal while the drive stays", calls.isEmpty, "\(calls)")

// A VM folder on the image.
func vmFolder() throws -> URL {
    let vm = mount.appendingPathComponent("VMs/Drop")
    try fm.createDirectory(at: vm.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try Data("NAME='Drop'\n".utf8).write(to: vm.appendingPathComponent("vm.env"))
    return vm
}
var vm = try vmFolder()
// The test keeps a file open on the drive, as QEMU keeps the VM's disk.
let disk = vm.appendingPathComponent("disk.img")
try Data(count: 4096).write(to: disk)
let held = FileHandle(forUpdatingAtPath: disk.path)!

calls = []
var watch = DriveWatch(folder: vm) { calls.append($0) }
expect("the image's folder is watched", watch != nil)
expect("its drive's name", watch?.name == volumeName, watch?.name ?? "nil")
expect("its mount point", watch?.mount.path == mount.standardizedFileURL.path, watch?.mount.path ?? "nil")
// Moving the folder on its drive (Finder) is no signal.
let moved = mount.appendingPathComponent("VMs/Moved")
try fm.moveItem(at: vm, to: moved)
wait(3) { !calls.isEmpty }
expect("moving the folder on its drive: no signal", calls.isEmpty, "\(calls)")
try fm.moveItem(at: moved, to: vm)

// The drive drops off (as a USB link that goes): detach by force while a
// file on it is open.
let imageDevice = Storage.device(mount)!
expect("detach -force", hdiutil(["detach", "-force", mount.path]) == 0)
// The 2 s poll's check sees it too (when no other signal came).
expect("drop: no longer mounted", !DriveWatch.mounted(imageDevice))
// The callback waits for the main queue, which hdiutil held until now.
let t0 = Date()
wait(8) { !calls.isEmpty }
expect("drop: one signal with the drive's name", calls == [volumeName], "\(calls)")
expect("drop: within 3 s", Date().timeIntervalSince(t0) < 3, "\(Date().timeIntervalSince(t0)) s")
wait(3) { calls.count > 1 }
expect("drop: only once", calls.count == 1, "\(calls)")
// QEMU's open file fails now; nothing written lands on the Mac's disk.
var writeFailed = false
do { try held.write(contentsOf: Data("x".utf8)); try held.synchronize() } catch { writeFailed = true }
expect("an open file on the gone drive fails", writeFailed)
try? held.close()
expect("the app's log lines find no qemu.log", FileHandle(forWritingAtPath: vm.appendingPathComponent("logs/qemu.log").path) == nil)
expect("nothing of the VM on the Mac's disk under the mount point",
       !fm.fileExists(atPath: vm.appendingPathComponent("vm.env").path))

// The drive is back: a new watch (the next start) is quiet, and one that
// was stopped (QEMU ended) says nothing when the drive goes again.
expect("drive back", hdiutil(["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image]) == 0)
vm = mount.appendingPathComponent("VMs/Drop")
expect("the VM is back on it", fm.fileExists(atPath: vm.appendingPathComponent("vm.env").path))
calls = []
watch = DriveWatch(folder: vm) { calls.append($0) }
wait(2.5) { false }
expect("drive back: no signal", calls.isEmpty, "\(calls)")
// stop() before a drop: nothing after it.
watch?.stop()
expect("detach -force again", hdiutil(["detach", "-force", mount.path]) == 0)
wait(3) { !calls.isEmpty }
expect("a stopped watch says nothing", calls.isEmpty, "\(calls)")

// A drive renamed while its VM runs (Finder, diskutil rename): its mount
// point moves to /Volumes/NEW, the drive stays: no signal. Its drop after
// that still is one. RENAME: the mount point of a second image, attached
// under /Volumes (only there does a rename move the mount point).
if args.count > 5 {
    let ren = URL(fileURLWithPath: args[5])
    let newName = ren.lastPathComponent + "R"
    let folder = ren.appendingPathComponent("VMs/Ren")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    calls = []
    watch = DriveWatch(folder: folder) { calls.append($0) }
    expect("rename: watched", watch != nil)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = ["rename", ren.path, newName]
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    let moved = URL(fileURLWithPath: "/Volumes").appendingPathComponent(newName)
    expect("rename: the mount point moved", p.terminationStatus == 0
           && fm.fileExists(atPath: moved.appendingPathComponent("VMs/Ren").path)
           && !fm.fileExists(atPath: ren.path), moved.path)
    wait(4.5) { !calls.isEmpty }
    expect("rename: no signal (two polls)", calls.isEmpty, "\(calls)")
    expect("rename: detach -force", hdiutil(["detach", "-force", moved.path]) == 0)
    wait(5) { !calls.isEmpty }
    expect("rename, then drop: one signal", calls.count == 1, "\(calls)")
    watch?.stop()
}

print(failed == 0 ? "PASS app-drive-drop" : "FAIL app-drive-drop: \(failed)")
exit(failed == 0 ? 0 : 1)
