import Foundation

/// The file `running` in a VM's folder while the app runs the VM: which Mac
/// and which QEMU. A clean stop removes it. Found at a start, it means the
/// VM was not shut down cleanly, or its folder was copied while it ran (on
/// 2026-10-09 a VM copied from a MacBook Pro while it ran came up on a
/// MacBook Air with a damaged btrfs). Foundation only:
/// src/tests/app-run-marker.sh compiles and tests it.
enum RunMarker {
    static let fileName = "running"

    struct Mark: Equatable {
        /// The Mac's hardware UUID (IOPlatformUUID).
        var mac: String
        /// The Mac's name, for the message.
        var name: String
        var pid: Int32
    }

    static func text(_ m: Mark) -> String {
        "mac=\(m.mac)\nname=\(m.name)\npid=\(m.pid)\n"
    }

    static func parse(_ s: String) -> Mark? {
        var v: [String: String] = [:]
        for line in s.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            v[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let mac = v["mac"], !mac.isEmpty, let pid = Int32(v["pid"] ?? "") else { return nil }
        return Mark(mac: mac, name: v["name"] ?? "", pid: pid)
    }

    static func read(_ folder: URL) -> Mark? {
        (try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8)).flatMap(parse)
    }

    /// The warning before a start (the caller has made sure no QEMU of this
    /// Mac runs the VM), or nil without a mark. A mark this app cannot read
    /// counts too.
    static func warning(folder: URL, thisMac: String, fm: FileManager = .default) -> String? {
        guard fm.fileExists(atPath: folder.appendingPathComponent(fileName).path) else { return nil }
        let m = read(folder)
        var s = "This VM was not shut down cleanly or was copied while running; its disk may be damaged."
        if let m, m.mac != thisMac, !m.name.isEmpty { s += " It last ran on \(m.name)." }
        return s
    }
}
