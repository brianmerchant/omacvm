import AppKit
import Foundation
import OmacVMFolder

/// The Mac folder setting (off by default): one folder of the Mac at ~/Mac in
/// the VM (MacFolderPlan says how). The VM's mac-folder file is the switch:
/// the folder's path, or no file. Applies from the VM's next start.
enum MacFolder {
    static func file(_ c: VMConfig) -> URL { c.folder.appendingPathComponent("mac-folder") }

    /// The folder this VM shares, nil when off.
    static func path(_ c: VMConfig) -> String? {
        MacFolderPlan.path(fromFile: try? String(contentsOf: file(c), encoding: .utf8))
    }

    /// QEMU's arguments for this start, and the qemu.log line.
    static func plan(_ c: VMConfig) -> MacFolderPlan.Plan {
        MacFolderPlan.plan(fileText: try? String(contentsOf: file(c), encoding: .utf8)) { p in
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && dir.boolValue
        }
    }

    /// Shares `url` from the next start (nil: off).
    static func set(_ url: URL?, for c: VMConfig) throws {
        guard let url else {
            try? FileManager.default.removeItem(at: file(c))
            return
        }
        try Data("\(url.standardizedFileURL.path)\n".utf8).write(to: file(c), options: .atomic)
    }

    /// Asks for the folder (the Finder's panel). nil: cancelled.
    @MainActor static func choose(current: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        panel.message = "The VM can read and change everything in this folder, at ~/Mac."
        panel.directoryURL = current.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}
