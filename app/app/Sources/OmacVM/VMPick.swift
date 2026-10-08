import Foundation

/// Which VM the app manages when it is named (--vm NAME, `omacvm`'s start
/// requests), and which folders a test build may touch. Foundation only:
/// src/tests/app-vm-pick.sh compiles and tests these rules on their own.
///
/// 2026-10-07: a test build got `--start --vm NAME` for a VM it did not find
/// (its VMs folder setting was gone) and fell back to the default folder,
/// ~/OmacVM/Omarchy, the person's own VM: it started it and its disk test
/// made that disk smaller. A name that is not found is an error, never
/// another VM.
enum VMPick {
    /// The name after --vm: nil without --vm, "" when --vm has no value.
    static func requested(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--vm") else { return nil }
        return i + 1 < args.count ? args[i + 1] : ""
    }

    enum Choice: Equatable {
        /// This one of the VMs found.
        case vm(Int)
        /// No VM yet: the setup for a new one.
        case new
        /// A name was given and no VM has it: start nothing, act on nothing.
        case unknown(String)
    }

    /// --vm NAME: that VM (by its name or its folder's name), else .unknown,
    /// never another VM. Without --vm: the first VM, else a new one.
    static func choose(requested: String?, vms: [(name: String, folder: String)]) -> Choice {
        if let want = requested {
            if !want.isEmpty, let i = vms.firstIndex(where: { $0.name == want || $0.folder == want }) {
                return .vm(i)
            }
            return .unknown(want)
        }
        return vms.isEmpty ? .new : .vm(0)
    }

    static func unknownText(_ name: String, roots: [URL]) -> String {
        let where_ = roots.map(\.path).joined(separator: ", ")
        if name.isEmpty { return "--vm needs a VM's name. Nothing was started." }
        return "No VM named \"\(name)\" in \(where_.isEmpty ? "the VMs folder" : where_). Nothing was started."
    }

    /// A name for a new VM whose folder in ROOT does not exist yet and that no
    /// VM has: BASE, else "BASE 2", "BASE 3" ... (like `omacvm build`). A new
    /// VM's folder is never one that is there already (a build into it would
    /// take over that VM's disk).
    static func freeName(_ base: String = "Omarchy", root: URL, taken: [String],
                         fm: FileManager = .default) -> String {
        func free(_ n: String) -> Bool {
            !taken.contains { $0.caseInsensitiveCompare(n) == .orderedSame }
                && !fm.fileExists(atPath: root.appendingPathComponent(n).path)
        }
        if free(base) { return base }
        var i = 2
        while !free("\(base) \(i)") { i += 1 }
        return "\(base) \(i)"
    }
}

/// The test builds' VMs. The test identity ("OmacVM Test",
/// org.omacvm.app.test) never uses the installed app's VMs folders: without
/// a setting of its own (or with one that is a folder of the installed app)
/// its VMs go into ~/OmacVM Test VMs. Destructive test hooks (the disk size,
/// forcing a VM off) act only on a VM in a VMs folder the test build was
/// given on purpose, and never on one in a folder of the installed app.
enum TestVMs {
    static let defaultName = "OmacVM Test VMs"

    /// Every folder the installed app (org.omacvm.app) keeps VMs in or would
    /// make: its setting, its older folders, ~/OmacVM and the old hidden
    /// place, for both $HOME and the account's home.
    static func productionRoots(custom: String?, others: [String], homes: [URL]) -> [URL] {
        var r: [URL] = []
        if let custom, !custom.isEmpty { r.append(URL(fileURLWithPath: custom)) }
        r += others.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        for h in homes {
            r.append(h.appendingPathComponent(VMsFolder.name))
            r.append(h.appendingPathComponent(VMsFolder.oldPath))
        }
        return r
    }

    /// A is B, or inside B: by path (symlinks resolved, any case: macOS
    /// drives mostly ignore it) and by the folders on disk (firmlinks, links).
    static func sameOrInside(_ a: URL, _ b: URL) -> Bool {
        let pa = a.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let pb = b.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        if pa == pb || pa.hasPrefix(pb.hasSuffix("/") ? pb : pb + "/") { return true }
        guard let target = fileID(b) else { return false }
        var path = a.standardizedFileURL.path
        while true {
            if fileID(URL(fileURLWithPath: path)) == target { return true }
            if path == "/" || path.isEmpty { return false }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    private struct FileID: Equatable { let dev: Int32; let ino: UInt64 }
    private static func fileID(_ u: URL) -> FileID? {
        var s = stat()
        guard stat(u.path, &s) == 0 else { return nil }
        return FileID(dev: s.st_dev, ino: s.st_ino)
    }

    static func isProduction(_ folder: URL, production: [URL]) -> Bool {
        production.contains { sameOrInside(folder, $0) }
    }

    /// Where the test identity's VMs go: its own setting, unless that is (in)
    /// a folder of the installed app; else ~/OmacVM Test VMs.
    static func root(custom: String?, home: URL, production: [URL]) -> URL {
        if let custom, !custom.isEmpty {
            let u = URL(fileURLWithPath: custom)
            if !isProduction(u, production: production) { return u }
        }
        return home.appendingPathComponent(defaultName)
    }

    /// Why the test identity does not use its VMs folder setting (nil: it does).
    static func refusedSetting(custom: String?, production: [URL]) -> String? {
        guard let custom, !custom.isEmpty else { return nil }
        guard isProduction(URL(fileURLWithPath: custom), production: production) else { return nil }
        return "the test identity's VMs folder \(custom) is a folder of the installed OmacVM: not used"
    }

    /// Why a test build (any bundle id but the release one: the test
    /// identity, a self-update test build, a lane's copy) must not start,
    /// update or resize the VM in FOLDER (nil: it may): a VM of the installed
    /// app, whatever led to it (a start request, Update VM, Disk, a restart
    /// after an update).
    static func startProblem(folder: URL, testBuild: Bool, production: [URL]) -> String? {
        guard testBuild, isProduction(folder, production: production) else { return nil }
        return "\(folder.path) is a VM of the installed OmacVM: a test build does not start or change it."
    }

    /// A test build hands a start (or a restart-update) to a launcher that
    /// runs already only when that is this same copy: another copy (an older
    /// build) may not know these rules and start another VM.
    static func handOverProblem(testBuild: Bool, mine: URL, other: URL?) -> String? {
        guard testBuild else { return nil }
        if let other, sameOrInside(mine, other) && sameOrInside(other, mine) { return nil }
        return "another copy of this app runs (\(other?.path ?? "macOS does not say where")): quit it first. Nothing was started."
    }

    /// Why a destructive test hook must not act on the VM in FOLDER (nil: it
    /// may): the VM must exist, sit directly in OWNROOT, the VMs folder the
    /// test build was given in its own setting, and be in no folder of the
    /// installed app.
    static func hookProblem(folder: URL?, ownRoot: String?, production: [URL],
                            fm: FileManager = .default) -> String? {
        guard let folder else { return "no VM of that name: the hook does nothing" }
        guard let ownRoot, !ownRoot.isEmpty else {
            return "this test build has no VMs folder setting of its own (vmsRoot): the hook does nothing"
        }
        if isProduction(folder, production: production) {
            return "\(folder.path) is a VM of the installed OmacVM: the hook does nothing"
        }
        let parent = folder.standardizedFileURL.deletingLastPathComponent()
        let root = URL(fileURLWithPath: ownRoot)
        guard sameOrInside(parent, root) && sameOrInside(root, parent) else {
            return "\(folder.path) is not in this test build's VMs folder \(ownRoot): the hook does nothing"
        }
        guard fm.fileExists(atPath: folder.appendingPathComponent("vm.env").path) else {
            return "\(folder.path) has no vm.env: the hook does nothing"
        }
        return nil
    }
}
