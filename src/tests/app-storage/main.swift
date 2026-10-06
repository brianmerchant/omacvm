// Offline tests of OmacVM.app's Storage.swift on fixture folders; run by
// src/tests/app-storage.sh. Arguments: WORK (an empty folder), DRIVE (a small
// mounted disk image: "another drive"), VOLUMES (a folder standing in for
// /Volumes, with DRIVE mounted at VOLUMES/Real), HFS (a small Mac OS Extended
// disk image: no sparse files).
import CryptoKit
import Foundation

setvbuf(stdout, nil, _IONBF, 0)   // each line at once, also when the test is killed
let args = CommandLine.arguments
let work = URL(fileURLWithPath: args[1]), drive = URL(fileURLWithPath: args[2]), volumes = URL(fileURLWithPath: args[3])
let hfs = URL(fileURLWithPath: args[4])
let fm = FileManager.default
var failed = 0

func expect(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) \(detail())"); failed += 1 }
}

func sha(_ url: URL) -> String {
    guard let h = FileHandle(forReadingAtPath: url.path) else { return "unreadable" }
    var hash = SHA256()
    // Each chunk released at once: CI runners have little memory.
    while autoreleasepool(invoking: { () -> Bool in
        guard let d = try? h.read(upToCount: 1 << 20), !d.isEmpty else { return false }
        hash.update(data: d)
        return true
    }) {}
    try? h.close()
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func allocated(_ url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? -1)
}

/// A VM folder: vm.env, a sparse 512 MB disk.img with 1 MB of data every
/// 4 MB (dataMB of them), efi-vars.fd, logs/, a symbolic link and a private file.
func makeVM(_ root: URL, _ name: String, dataMB: Int = 3) throws -> URL {
    let d = root.appendingPathComponent(name)
    try fm.createDirectory(at: d.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try "NAME='\(name)'\nCPUS=4\n".write(to: d.appendingPathComponent("vm.env"), atomically: true, encoding: .utf8)
    let disk = d.appendingPathComponent("disk.img")
    fm.createFile(atPath: disk.path, contents: nil)
    let h = try FileHandle(forWritingTo: disk)
    try h.truncate(atOffset: 512 << 20)
    let mb = [UInt8](repeating: 0, count: 1 << 20)
    for i in 0..<dataMB {
        var block = mb
        for j in stride(from: 0, to: block.count, by: 4096) { block[j] = UInt8(truncatingIfNeeded: i * 31 + j / 4096 + 1) }
        try h.seek(toOffset: UInt64(i) * (4 << 20))
        h.write(Data(block))
    }
    // A data block of zeros: read as data, written as a hole.
    try h.seek(toOffset: 500 << 20)
    h.write(Data(mb))
    try h.close()
    try Data(repeating: 7, count: 65536).write(to: d.appendingPathComponent("efi-vars.fd"))
    try "boot\n".write(to: d.appendingPathComponent("logs/qemu.log"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(atPath: d.appendingPathComponent("latest.log").path, withDestinationPath: "logs/qemu.log")
    try "secret".write(to: d.appendingPathComponent("fast-network"), atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: d.appendingPathComponent("fast-network").path)
    return d
}

func fingerprint(_ d: URL) -> [String: String] {
    var out: [String: String] = [:]
    for case let rel as String in fm.enumerator(atPath: d.path)! {
        let u = d.appendingPathComponent(rel)
        let a = try! fm.attributesOfItem(atPath: u.path)
        let perm = String(format: "%o", (a[.posixPermissions] as? Int) ?? 0)
        switch a[.type] as? FileAttributeType {
        case .typeSymbolicLink?: out[rel] = "link " + ((try? fm.destinationOfSymbolicLink(atPath: u.path)) ?? "")
        case .typeDirectory?: out[rel] = "dir " + perm
        default: out[rel] = "file \(perm) \((a[.size] as? Int) ?? -1) \(sha(u))"
        }
    }
    return out
}

do {
    // Drives
    try fm.createDirectory(at: volumes.appendingPathComponent("Stale"), withIntermediateDirectories: true)
    expect("missing drive: a stale folder", Storage.missingDrive(for: volumes.appendingPathComponent("Stale/OmacVM"), volumes: volumes) == "Stale")
    expect("missing drive: no folder", Storage.missingDrive(for: volumes.appendingPathComponent("Gone/OmacVM"), volumes: volumes) == "Gone")
    expect("missing drive: mounted", Storage.missingDrive(for: volumes.appendingPathComponent("Real/OmacVM"), volumes: volumes) == nil)
    expect("missing drive: not under Volumes", Storage.missingDrive(for: work.appendingPathComponent("x"), volumes: volumes) == nil)
    expect("missing drive: the real /Volumes, home", Storage.missingDrive(for: fm.homeDirectoryForCurrentUser) == nil)
    expect("same volume: two folders here", Storage.sameVolume(work.appendingPathComponent("a/b"), work))
    expect("same volume: the disk image is another", !Storage.sameVolume(work, drive))
    expect("free space of a folder not made yet", (Storage.freeBytes(at: work.appendingPathComponent("no/such")) ?? 0) > 0)

    // Same drive: a rename
    let r1 = work.appendingPathComponent("root1"), r2 = work.appendingPathComponent("root2")
    let vm = try makeVM(r1, "Omarchy")
    let before = fingerprint(vm)
    let inode = (try fm.attributesOfItem(atPath: vm.appendingPathComponent("disk.img").path))[.systemFileNumber] as? Int
    let moved = try FolderMover().move(vm, into: r2)
    expect("same drive: new place", moved.path == r2.appendingPathComponent("Omarchy").path)
    expect("same drive: old place gone", !fm.fileExists(atPath: vm.path))
    expect("same drive: same files", fingerprint(moved) == before)
    let inode2 = (try fm.attributesOfItem(atPath: moved.appendingPathComponent("disk.img").path))[.systemFileNumber] as? Int
    expect("same drive: renamed, not copied", inode == inode2)

    // Target exists
    _ = try makeVM(r1, "Omarchy")
    do { _ = try FolderMover().move(r1.appendingPathComponent("Omarchy"), into: r2); expect("existing target refused", false) }
    catch { expect("existing target refused", "\(error.localizedDescription)".contains("already exists"), error.localizedDescription) }
    expect("existing target: source kept", fm.fileExists(atPath: r1.appendingPathComponent("Omarchy/disk.img").path))

    // Another drive: copy, check, delete; sparse kept (2 GB logical on a 64 MB drive)
    let ext = drive.appendingPathComponent("OmacVM")
    var phases = Set<String>(), last: Int64 = 0, total: Int64 = 0, monotonic = true
    let m = FolderMover()
    m.progress = { phase, done, all in
        if phases.insert(phase).inserted { last = 0 }
        if done < last { monotonic = false }
        last = done; total = all
    }
    let onExt = try m.move(moved, into: ext)
    expect("other drive: new place", onExt.path == ext.appendingPathComponent("Omarchy").path)
    expect("other drive: old place gone", !fm.fileExists(atPath: moved.path))
    expect("other drive: same files, modes and links", fingerprint(onExt) == before,
           "\(fingerprint(onExt).filter { before[$0.key] != $0.value })")
    let alloc = allocated(onExt.appendingPathComponent("disk.img"))
    expect("other drive: disk stays sparse", alloc > 0 && alloc < 16 << 20, "allocated \(alloc)")
    expect("other drive: copied and checked", phases == ["Copying", "Checking"], "\(phases)")
    expect("other drive: progress counts up to the data size", monotonic && last == total && total >= 4 << 20, "\(last)/\(total)")
    expect("other drive: no half copy left", !fm.fileExists(atPath: ext.appendingPathComponent(".Omarchy.moving").path))

    // Back from the other drive
    let back = try FolderMover().move(onExt, into: r2)
    expect("back again: same files", fingerprint(back) == before)

    // Time Machine's exclusion: a copy to another drive drops it, the mover sets it again
    let tmVM = try makeVM(r1, "Tm", dataMB: 1)
    Storage.excludeFromBackup(tmVM)
    let tmExt = try FolderMover().move(tmVM, into: ext)
    expect("other drive: still left out of Time Machine", Storage.isExcludedFromBackup(tmExt))
    let tmBack = try FolderMover().move(tmExt, into: r1)
    expect("back again: still left out of Time Machine", Storage.isExcludedFromBackup(tmBack))
    try fm.removeItem(at: tmBack)

    // Something writes into the folder during the move: the original stays
    func changedDuringMove(_ name: String, _ change: @escaping (URL) throws -> Void) throws -> (String, URL) {
        let v = try makeVM(r1, name, dataMB: 1)
        let mv = FolderMover()
        var once = false
        mv.progress = { phase, _, _ in
            if phase == "Checking" && !once { once = true; try? change(v) }
        }
        do { _ = try mv.move(v, into: ext); return ("moved", v) }
        catch { return (error.localizedDescription, v) }
    }
    let (grew, grow) = try changedDuringMove("Grow") { v in
        try "1 2\n".write(to: v.appendingPathComponent("guest-pointer"), atomically: false, encoding: .utf8)
    }
    expect("a file that appears during the move: refused", grew.contains("guest-pointer") && grew.contains("changed during the move"), grew)
    expect("a file that appears: it and the original stay", fm.fileExists(atPath: grow.appendingPathComponent("guest-pointer").path)
           && fm.fileExists(atPath: grow.appendingPathComponent("disk.img").path))
    expect("a file that appears: no copy left", !fm.fileExists(atPath: ext.appendingPathComponent("Grow").path)
           && !fm.fileExists(atPath: ext.appendingPathComponent(".Grow.moving").path))
    // Same size, new contents: only the modification time tells.
    let (edited, edit) = try changedDuringMove("Edit") { v in
        try "NAME='Edit'\nCPUS=8\n".write(to: v.appendingPathComponent("vm.env"), atomically: false, encoding: .utf8)
    }
    expect("a file changed during the move: refused", edited.contains("vm.env") && edited.contains("changed during the move"), edited)
    expect("a file changed: the new contents stay", (try? String(contentsOf: edit.appendingPathComponent("vm.env"), encoding: .utf8)) == "NAME='Edit'\nCPUS=8\n")
    expect("a file changed: no copy left", !fm.fileExists(atPath: ext.appendingPathComponent("Edit").path))
    try fm.removeItem(at: grow); try fm.removeItem(at: edit)

    // A VM folder that is a link: refused, the link and its folder stay
    let real = try makeVM(work.appendingPathComponent("elsewhere"), "Linked", dataMB: 1)
    let realBefore = fingerprint(real)
    let link = r1.appendingPathComponent("Linked")
    try fm.createSymbolicLink(at: link, withDestinationURL: real)
    for (what, into) in [("other drive", ext), ("same drive", r2)] {
        do { _ = try FolderMover().move(link, into: into); expect("link refused (\(what))", false) }
        catch { expect("link refused (\(what))", error.localizedDescription.contains("is a link to \(real.path)"), error.localizedDescription) }
    }
    expect("link refused: link and folder kept", (try? fm.destinationOfSymbolicLink(atPath: link.path)) == real.path
           && fingerprint(real) == realBefore && !fm.fileExists(atPath: ext.appendingPathComponent("Linked").path))
    try fm.removeItem(at: link)

    // Half copies left by a quit during a move: removed at the next launch, nothing else
    let ghost = ext.appendingPathComponent(".Ghost.moving")
    try fm.createDirectory(at: ghost.appendingPathComponent("logs"), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: ghost.appendingPathComponent("disk.img"))
    try Data().write(to: ext.appendingPathComponent(".file.moving"))
    try fm.createDirectory(at: ext.appendingPathComponent(".moving"), withIntermediateDirectories: true)
    let kept = work.appendingPathComponent("kept")
    try fm.createDirectory(at: kept, withIntermediateDirectories: true)
    try "x".write(to: kept.appendingPathComponent("a"), atomically: true, encoding: .utf8)
    try fm.createSymbolicLink(at: ext.appendingPathComponent(".Link.moving"), withDestinationURL: kept)
    let extBefore = Set(try fm.contentsOfDirectory(atPath: ext.path))
    let removed = Storage.removeStaleMoves(in: [ext, URL(fileURLWithPath: "/Volumes/OmacVM-no-such-drive/VMs"),
                                                work.appendingPathComponent("no-such")])
    expect("stale half copy removed", removed.map(\.lastPathComponent) == [".Ghost.moving"] && !fm.fileExists(atPath: ghost.path),
           "\(removed)")
    expect("stale half copies: nothing else touched",
           Set(try fm.contentsOfDirectory(atPath: ext.path)) == extBefore.subtracting([".Ghost.moving"])
           && fm.fileExists(atPath: kept.appendingPathComponent("a").path))
    for n in [".file.moving", ".moving", ".Link.moving"] { try fm.removeItem(at: ext.appendingPathComponent(n)) }

    // Too big for the drive: refused before copying, nothing changes
    let big = try makeVM(r1, "Big", dataMB: 90)
    let bigBefore = fingerprint(big)
    do { _ = try FolderMover().move(big, into: ext); expect("too big refused", false) }
    catch { expect("too big refused", error.localizedDescription.contains("free there"), error.localizedDescription) }
    expect("too big: source unchanged", fingerprint(big) == bigBefore)

    // Mac OS Extended: the 512 MB disk would take 512 MB there
    let small = try makeVM(work.appendingPathComponent("root4"), "Small", dataMB: 1)
    do { _ = try FolderMover().move(small, into: hfs.appendingPathComponent("VMs")); expect("no sparse files: full size counted", false) }
    catch { expect("no sparse files: full size counted", error.localizedDescription.contains("536.9 MB to copy"), error.localizedDescription) }
    expect("no sparse files: source kept", fm.fileExists(atPath: small.appendingPathComponent("disk.img").path))

    // Cancel during the copy: the source stays, no half copy
    let mid = try makeVM(work.appendingPathComponent("root3"), "Mid", dataMB: 4)
    let midBefore = fingerprint(mid)
    let c = FolderMover()
    c.progress = { _, done, _ in if done > 0 { c.cancel() } }
    do { _ = try c.move(mid, into: ext); expect("cancel stops the move", false) }
    catch { expect("cancel stops the move", error as? StorageError == .cancelled, "\(error)") }
    expect("cancel: source unchanged", fingerprint(mid) == midBefore)
    expect("cancel: no half copy", !fm.fileExists(atPath: ext.appendingPathComponent(".Mid.moving").path)
           && !fm.fileExists(atPath: ext.appendingPathComponent("Mid").path))

    // A drive that is not connected
    do { _ = try FolderMover().move(mid, into: URL(fileURLWithPath: "/Volumes/OmacVM-no-such-drive/VMs")); expect("missing drive refused", false) }
    catch { expect("missing drive refused", error.localizedDescription.contains("not connected"), error.localizedDescription) }

    // Busy folders and downloads in use
    let lines = ["/x/OmacVM -drive if=none,id=disk,file=\(r2.path)/Omarchy/disk.img,format=raw",
                 "/bin/bash /x/create-vm.sh \(work.path)/root3/Mid", "vim notes.txt"]
    let busy = Storage.busyFolders([back, mid, big], lines: lines).map(\.lastPathComponent)
    expect("busy: QEMU's disk and a build", busy == ["Omarchy", "Mid"], "\(busy)")
    let comma = work.appendingPathComponent("a,b")
    expect("busy: a comma doubled on QEMU's line",
           Storage.busyFolders([comma], lines: ["qemu file=\(work.path)/a,,b/disk.img,format=raw"]).count == 1)
    expect("busy: none", Storage.busyFolders([big], lines: ["other \(big.path)x"]).isEmpty)
    let caches = work.appendingPathComponent("Caches/omacvm")
    expect("downloads in use: curl into them", Storage.downloadsInUse(caches, lines: ["curl -o \(caches.path)/live/x.dmg"]))
    expect("downloads in use: omacvm build", Storage.downloadsInUse(caches, lines: ["/bin/bash /u/.omacvm/omacvm build --vm-type app"]))
    expect("downloads not in use", !Storage.downloadsInUse(caches, lines: ["zsh", "/Applications/Safari.app"]))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "exec -a 'OmacVM -drive file=\(back.path)/disk.img,format=raw' sleep 20"]
    try p.run()
    Thread.sleep(forTimeInterval: 0.5)
    expect("busy: a real process", Storage.busyFolders([back, big]).map(\.lastPathComponent) == ["Omarchy"])
    p.terminate()

    // Clear downloads
    try fm.createDirectory(at: caches.appendingPathComponent("live"), withIntermediateDirectories: true)
    try "x".write(to: caches.appendingPathComponent("live/a.dmg"), atomically: true, encoding: .utf8)
    try "x".write(to: caches.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
    try Storage.clear(caches)
    expect("clear: folder empty, folder kept", fm.fileExists(atPath: caches.path) && ((try? fm.contentsOfDirectory(atPath: caches.path)) ?? ["?"]).isEmpty)

    // Sizes and Time Machine
    expect("size of a VM counts what the disk holds", Storage.allocatedSize(of: back) < 64 << 20 && Storage.allocatedSize(of: back) > 3 << 20)
    Storage.excludeFromBackup(back)
    let tm = Process(), out = Pipe()
    tm.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
    tm.arguments = ["isexcluded", back.path]
    tm.standardOutput = out
    try tm.run(); tm.waitUntilExit()
    expect("Time Machine leaves it out", String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains("[Excluded]"))

    // The app into ~/Applications
    let sys = work.appendingPathComponent("Applications"), home = work.appendingPathComponent("home/Applications")
    let app = sys.appendingPathComponent("OmacVM.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try "x".write(to: app.appendingPathComponent("Contents/MacOS/OmacVM"), atomically: true, encoding: .utf8)
    let newApp = try AppMover.move(app, into: home)
    expect("app moved", newApp.path == home.appendingPathComponent("OmacVM.app").path && !fm.fileExists(atPath: app.path)
           && fm.fileExists(atPath: newApp.appendingPathComponent("Contents/MacOS/OmacVM").path))
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    do { _ = try AppMover.move(app, into: home); expect("app: existing copy refused", false) }
    catch { expect("app: existing copy refused", fm.fileExists(atPath: app.path)) }
} catch {
    print("FAIL unexpected: \(error)")
    failed += 1
}
print(failed == 0 ? "all passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
