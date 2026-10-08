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
}
