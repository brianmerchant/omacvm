import Foundation

/// "Open existing VM…": a VM folder picked in the Finder (one with vm.env, or
/// the folder it is in) becomes the shown VM, its folder's parent the VMs
/// folder. Foundation only: src/tests/app-open-vm.sh compiles and tests it.
enum VMOpen {
    enum Pick: Equatable {
        /// The VM in FOLDER; ROOT (its parent) becomes the VMs folder.
        case vm(folder: URL, root: URL)
        /// Nothing to open: the plain reason.
        case none(String)
    }

    /// The picked folder is a VM folder (vm.env in it), else the folder of
    /// one or more VMs: the first by name.
    static func pick(_ url: URL, fm: FileManager = .default) -> Pick {
        let u = url.standardizedFileURL
        if fm.fileExists(atPath: u.appendingPathComponent("vm.env").path) {
            return .vm(folder: u, root: u.deletingLastPathComponent())
        }
        let items = (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
        if let vm = items.sorted(by: { $0.path < $1.path })
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("vm.env").path) }) {
            return .vm(folder: vm.standardizedFileURL, root: u)
        }
        return .none("No VM in \(u.path). A VM's folder has a file named vm.env in it: pick that folder, or the folder it is in.")
    }

    /// QEMU could not lock the VM's disk: another QEMU has it open (another
    /// copy of the app, or another Mac on a shared drive).
    static func diskLocked(log: String) -> Bool {
        log.contains("Failed to get \"write\" lock") || log.contains("Is another process using the image")
    }

    static func diskLockedText(_ name: String) -> String {
        "\(name) is in use by another app or Mac (its disk is locked). Shut it down there first, then start it here."
    }

    /// A QEMU of this Mac runs from FOLDER's disk (another copy of the app,
    /// say). ps lines; QEMU doubles commas in its options.
    static func qemuRuns(_ folder: URL, lines: [String]) -> Bool {
        let disk = folder.standardizedFileURL.path.replacingOccurrences(of: ",", with: ",,") + "/disk.img,"
        return lines.contains { $0.contains("file=" + disk) }
    }
}
