import CoreGraphics
import Darwin
import Foundation

/// OmacVM.app: its VM window belongs to the app's QEMU, whose process may carry
/// any name the user gave the app. Its executable is always
/// <app>/Contents/Resources/runtime/bin/OmacVM, so windows of that process
/// count as owner "OmacVM". Its VMs reach the Mac at 127.0.0.1 (or at
/// 192.168.77.1 on its fast network) and must prove they know OmacVM's Bridge
/// token first, since any Mac program can connect there (GuestAuth).
enum OmacVMApp {
    static let owner = "OmacVM"

    private static var cache: [pid_t: Bool] = [:]

    static func isQEMU(_ pid: pid_t) -> Bool {
        if let hit = cache[pid] { return hit }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        let hit = n > 0 && String(cString: buf).hasSuffix("/Contents/Resources/runtime/bin/OmacVM")
        if cache.count > 64 { cache.removeAll() }
        cache[pid] = hit
        return hit
    }

    /// The owner name of a window-list entry, OmacVM.app's QEMU as "OmacVM".
    static func ownerName(_ w: [String: Any]) -> String? {
        if let pid = w[kCGWindowOwnerPID as String] as? Int, isQEMU(pid_t(pid)) { return owner }
        return w[kCGWindowOwnerName as String] as? String
    }
}
