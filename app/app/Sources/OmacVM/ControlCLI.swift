import Foundation

/// The omacvm OmacVM Bridge runs for the control centre's Mac jobs (the file
/// `cli` in OmacVM's support folder, read by src/bridge/mac/control.swift).
/// Without a checkout on the Mac it is this app's own copy
/// (Contents/Resources/omacvm/omacvm). Each start points the file at this app,
/// so it follows an update or a move; a checkout that is still there keeps it
/// (a CLI install). The same rule as cli_file_app in src/lib/mac.sh.
enum ControlCLI {
    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(TestIdentity.isOn ? "omacvm-test" : "omacvm")
    }

    /// The path to write, or nil to leave the file as it is.
    static func choose(current: String?, app: String, exists: (String) -> Bool) -> String? {
        guard app.hasPrefix("/"), app.hasSuffix("/Contents/Resources/omacvm/omacvm"), exists(app) else { return nil }
        let cur = (current ?? "").split(separator: "\n").first.map(String.init) ?? ""
        if cur == app { return nil }
        if !cur.isEmpty, exists(cur), !cur.hasSuffix("/Contents/Resources/omacvm/omacvm") { return nil }
        return app
    }

    static func refresh(bundle: URL = Bundle.main.bundleURL) {
        let app = bundle.appendingPathComponent("Contents/Resources/omacvm/omacvm").path
        let file = supportFolder.appendingPathComponent("cli")
        let current = try? String(contentsOf: file, encoding: .utf8)
        var isDir: ObjCBool = false
        guard let path = choose(current: current, app: app, exists: {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && !isDir.boolValue
        }) else { return }
        do {
            try FileManager.default.createDirectory(at: supportFolder, withIntermediateDirectories: true)
            let tmp = supportFolder.appendingPathComponent("cli.new")
            try? FileManager.default.removeItem(at: tmp)
            guard FileManager.default.createFile(atPath: tmp.path, contents: Data((path + "\n").utf8),
                                                 attributes: [.posixPermissions: 0o600]),
                  rename(tmp.path, file.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            FileHandle.standardError.write(Data("control: the Bridge runs \(path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("control: could not write \(file.path): \(error.localizedDescription)\n".utf8))
        }
    }
}
