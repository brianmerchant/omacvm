import Foundation

/// The Mac folder (off by default): one folder of the Mac, shown in the VM at
/// ~/Mac. QEMU shares it over virtio-9p with its local backend, running as the
/// Mac user, so the VM reaches only what is inside that folder and only what
/// the Mac user may (QEMU opens each path below the folder without following
/// symlinks out of it). The VM's mac-folder file holds the path; the VM
/// mounts the share at each boot when it is there (omacvm-mac-folder).
/// Apart from the app so `swift run folder-tests` can check it.
public enum MacFolderPlan {
    /// The share's name in the VM (omacvm-mac-folder looks for it).
    public static let tag = "omacvm-mac"
    /// Omarchy's desktop user: the Mac user's files show as theirs
    /// (qemu-9p-guest-owner.patch), so the VM's own permission checks agree.
    public static let guestUID = 1000

    /// The folder in a mac-folder file's text: one absolute path on its first
    /// line; nil when the file is empty (off) or the path is not usable.
    public static func path(fromFile text: String?) -> String? {
        guard let line = text?.split(separator: "\n", omittingEmptySubsequences: false).first else { return nil }
        let p = String(line)
        guard p.hasPrefix("/"), p != "/", !p.contains("\0") else { return nil }
        // QEMU itself must not see "..": the folder is what the user picked.
        guard !p.split(separator: "/").contains("..") else { return nil }
        return p
    }

    /// What a start of the VM gets: QEMU's arguments and the line for
    /// qemu.log (omacvm check reads it).
    public struct Plan: Equatable {
        public let arguments: [String]
        public let record: String
    }

    /// The plan for a start. `fileText`: the mac-folder file (nil: none);
    /// `isDirectory`: the folder is there now. A folder that is not there (a
    /// drive not connected, moved) is left out for this start, so the VM still
    /// starts; QEMU would refuse to start otherwise.
    public static func plan(fileText: String?, isDirectory: (String) -> Bool) -> Plan {
        guard let text = fileText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Plan(arguments: [], record: "off")
        }
        guard let p = path(fromFile: text) else {
            return Plan(arguments: [], record: "off this start: the setting is not a usable folder (choose it again)")
        }
        guard isDirectory(p) else {
            return Plan(arguments: [], record: "off this start: \(p) is not there (a drive not connected?)")
        }
        // QEMU option values split at commas; a comma in a value is written twice.
        let q = p.replacingOccurrences(of: ",", with: ",,")
        return Plan(arguments: [
            // security_model=none: files keep the Mac user's owner and modes;
            // the VM sees them as its desktop user's. multidevs=remap: a disk
            // mounted inside the folder cannot give two files the same id.
            "-fsdev", "local,id=macfs,path=\(q),security_model=none,multidevs=remap,guest_owner_uid=\(guestUID),guest_owner_gid=\(guestUID)",
            "-device", "virtio-9p-pci,fsdev=macfs,mount_tag=\(tag)",
        ], record: "\(p) at ~/Mac")
    }
}
