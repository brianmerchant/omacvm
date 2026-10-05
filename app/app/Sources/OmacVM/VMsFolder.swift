import Foundation

/// Where the app's VMs live: one folder per VM inside the VMs folder.
///   1. the folder picked in the setup (setting vmsRoot), else
///   2. ~/OmacVM when it is there, else
///   3. the old place, ~/Library/Application Support/OmacVM/VMs, while it
///      holds VMs (nothing is moved), else
///   4. ~/OmacVM, made on first use (Spotlight skips it).
/// src/lib/app.sh (app_vms_root) follows the same rules: keep both in step
/// (src/tests/app-paths.sh checks that they agree).
enum VMsFolder {
    static let name = "OmacVM"
    static let oldPath = "Library/Application Support/OmacVM/VMs"

    /// $HOME as the omacvm command sees it, else the account's home.
    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], h.hasPrefix("/") {
            return URL(fileURLWithPath: h)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func resolve(custom: String?, home: URL, fm: FileManager = .default) -> URL {
        if let custom, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        let new = home.appendingPathComponent(name)
        if isOurs(new, home: home, fm: fm) { return new }
        let old = home.appendingPathComponent(oldPath)
        if hasVMs(old, fm: fm) || taken(new, home: home, fm: fm) { return old }
        return new
    }

    /// ~/OmacVM is a folder under exactly that name and no git clone. On a
    /// case-insensitive drive ~/omacvm is the same folder: never use that.
    static func isOurs(_ folder: URL, home: URL, fm: FileManager) -> Bool {
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &dir), dir.boolValue else { return false }
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        return names.contains(name) && !fm.fileExists(atPath: folder.appendingPathComponent(".git").path)
    }

    /// Something else already has the name (a file, ~/omacvm, a clone).
    static func taken(_ folder: URL, home: URL, fm: FileManager) -> Bool {
        fm.fileExists(atPath: folder.path) && !isOurs(folder, home: home, fm: fm)
    }

    static func hasVMs(_ folder: URL, fm: FileManager) -> Bool {
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.contains { fm.fileExists(atPath: $0.appendingPathComponent("vm.env").path) }
    }

    /// Before a VM goes in: makes ~/OmacVM when it is the VMs folder, with
    /// .metadata_never_index so Spotlight does not index the VM disks.
    static func prepare(_ root: URL, home: URL, fm: FileManager = .default) throws {
        let new = home.appendingPathComponent(name)
        guard root.standardizedFileURL.path == new.standardizedFileURL.path else { return }
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        let marker = new.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            guard fm.createFile(atPath: marker.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: marker.path])
            }
        }
    }
}
