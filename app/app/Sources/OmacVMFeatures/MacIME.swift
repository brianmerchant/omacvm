import Foundation

/// The Mac's input methods in the VM (feature mac-ime, experimental, off by
/// default; docs/adr/0043-mac-ime.md). OmacVM.app gives a VM the virtio port
/// org.omacvm.ime and tells QEMU's window code its socket only when the VM's
/// record (its features file, written by `omacvm apply`) says mac-ime=on, so
/// a VM with it off starts exactly as before: same devices, keys as before.
/// Apart from the UI so it is tested without a VM: `swift run features-tests`.
public enum MacIME {
    public static let feature = "mac-ime"
    public static let portName = "org.omacvm.ime"
    /// After org.omacvm.auth (7) on vser0: a port moves no PCI device.
    public static let portNumber = 8

    /// The record's word for it; anything but "on" (or no record) is off.
    public static func isOn(features text: String?) -> Bool {
        guard let text else { return false }
        var on = false
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == Substring(feature) { on = kv[1] == "on" }
        }
        return on
    }

    /// QEMU's arguments for the port (`socket` already quoted for QEMU's
    /// option syntax). QEMU's window code connects to the socket itself.
    public static func arguments(socket: String) -> [String] {
        ["-chardev", "socket,id=ime0,path=\(socket),server=on,wait=off",
         "-device", "virtserialport,bus=vser0.0,nr=\(portNumber),chardev=ime0,name=\(portName)"]
    }

    /// The environment variable that turns QEMU's side on (omacvm-cocoa-ime.patch).
    public static let socketVariable = "OMACVM_IME_SOCKET"

    // MARK: switched in the app while the VM is stopped (#316)

    /// The VM folder's file with a choice made in the app while the VM was
    /// stopped ("on" or "off"). The record says it already, so the next start
    /// has the port (or none); once the VM answers, the app runs `omacvm
    /// apply` for the VM's part and removes the file when that worked.
    public static let pendingFile = "mac-ime-pending"

    /// The pending choice from that file's text; nil when there is none.
    public static func pending(_ text: String?) -> Bool? {
        switch text?.split(whereSeparator: { $0 == " " || $0 == "\n" }).first {
        case "on": return true
        case "off": return false
        default: return nil
        }
    }

    /// A switch while the VM is stopped: the new record (mac-ime set, the
    /// other words as they were) and the pending file's text, nil to remove
    /// it (switched back before a start: the VM still has what it had).
    public static func switchStopped(record: String?, pending current: String?, on: Bool) -> (record: String, pending: String?) {
        var words = (record ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        let word = "\(feature)=\(on ? "on" : "off")"
        if let i = words.firstIndex(where: { $0.hasPrefix("\(feature)=") }) { words[i] = word } else { words.append(word) }
        let p = pending(current)
        let next: String? = p == nil ? (on ? "on" : "off") : (p == on ? (on ? "on" : "off") : nil)
        return (words.joined(separator: " ") + "\n", next.map { $0 + "\n" })
    }

    /// At the VM's start, before its links are read: the pending choice, or
    /// nil; the record (FOLDER/features) follows it (an apply that failed
    /// and rolled back may have reset it), so this start has the port or not.
    public static func prepareStart(folder f: URL) -> Bool? {
        guard let on = pending(try? String(contentsOf: f.appendingPathComponent(pendingFile), encoding: .utf8)) else { return nil }
        let url = f.appendingPathComponent("features")
        let text = try? String(contentsOf: url, encoding: .utf8)
        if isOn(features: text) != on {
            try? switchStopped(record: text, pending: nil, on: on).record.write(to: url, atomically: true, encoding: .utf8)
        }
        return on
    }

    /// The app's omacvm at the start: the VM's part for the pending choice
    /// (only that part: apply's feature switch).
    public static func applyArguments(vm: String, on: Bool) -> [String] {
        ["apply", "--vm", vm, "--vm-type", "app", "--feature", "\(feature)=\(on ? "on" : "off")", "--yes", "--transaction"]
    }

    /// The app's row: on or off (a pending choice over the record), whether
    /// it can be switched now, and its note. Stopped: it is written down for
    /// the next start. Running: `omacvm enable|disable` as before.
    public struct Row: Equatable {
        public var on: Bool
        public var enabled: Bool
        public var note: String?
        public init(on: Bool, enabled: Bool, note: String?) { self.on = on; self.enabled = enabled; self.note = note }
    }

    public static func row(record: String?, pending text: String?, running: Bool, busy: Bool, cli: Bool) -> Row {
        let p = pending(text)
        let on = p ?? isOn(features: record)
        if busy { return Row(on: on, enabled: false, note: nil) }
        if !running { return Row(on: on, enabled: true, note: p == nil ? nil : "From the next start.") }
        return Row(on: on, enabled: cli, note: p == nil ? nil : "Being set up in the VM for this start.")
    }
}
