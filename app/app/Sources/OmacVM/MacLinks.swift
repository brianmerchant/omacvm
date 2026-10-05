import Foundation

/// What of the Mac one VM may use, from its features: `omacvm apply` writes
/// them into the VM's folder (`features`: "bridge=on gestures=off ...").
/// A feature that is off gets nothing from the Mac: its port on the Mac's
/// 127.0.0.1 stays closed to this VM (patched libslirp) and the app does not
/// serve its virtio port. No file (a VM set up before this): everything, as
/// before. The fast network (vmnet) reaches the Mac directly: there only the
/// VM side keeps a feature that is off away from the Mac.
struct MacLinks: Equatable {
    var omanotch = true   // Omanotch, 127.0.0.1:47811
    var gestures = true   // OmacVM Gestures, 127.0.0.1:47830
    var bridge = true     // OmacVM Bridge, 127.0.0.1:47831
    var battery = true    // the app's battery port
    var camera = true     // the app's camera port

    init() {}

    /// From the file's text; a feature it does not name stays on.
    init(features text: String) {
        var on: [String: Bool] = [:]
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let kv = word.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { on[String(kv[0])] = kv[1] == "on" }
        }
        omanotch = on["omanotch"] ?? true
        gestures = on["gestures"] ?? true
        bridge = on["bridge"] ?? true
        battery = on["battery"] ?? true
        camera = on["camera"] ?? true
    }

    static func load(folder: URL) -> MacLinks {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("features"), encoding: .utf8) else {
            return MacLinks()
        }
        return MacLinks(features: text)
    }

    /// OMACVM_SLIRP_HOST_PORTS: empty means none.
    var hostPorts: String {
        [(omanotch, "47811"), (gestures, "47830"), (bridge, "47831")].filter { $0.0 }.map { $0.1 }.joined(separator: ",")
    }

    /// For qemu.log, which omacvm check reads: "Omanotch on, Gestures off, ...".
    var record: String {
        [("Omanotch", omanotch), ("Gestures", gestures), ("Bridge", bridge), ("battery", battery), ("camera", camera)]
            .map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: ", ")
    }
}
