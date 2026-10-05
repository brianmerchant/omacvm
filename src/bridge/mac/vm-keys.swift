// Media keys into an OmacVM.app VM: the VM in front gets a key press through
// QEMU's control socket (QMP, "input-send-event"), so Omarchy sees
// XF86AudioRaiseVolume, XF86AudioPlay & co. and does what its own keys do
// (its volume popup, playerctl). The socket is the one on the VM's QEMU
// command line (OmacVM.app's run folder); it serves one client at a time and
// the app uses it now and then, so a busy socket is a failure here (the key
// then goes to macOS, VMKeys.repost).
//
// Threading: socket(for:) on the main thread (the tap); press() on the
// Bridge's key queue, never in the tap callback.
import AppKit
import Darwin

final class VMKeys {
  private var paths: [pid_t: String] = [:]    // main thread: QEMU pid -> its QMP socket (hits only)
  static let marker: Int64 = 0x0BAC_0E5C      // a key the Bridge handed back to macOS

  /// The QMP socket of this QEMU (OmacVM.app's VM), nil if it has none we may use.
  func socket(for pid: pid_t) -> String? {
    if let p = paths[pid] { return p }
    if paths.count > 32 { paths = [:] }   // old VMs
    // Not found yet (QEMU still starting, its socket not made): asked again
    // on the next key, never remembered as "none".
    let p = VMKeys.arguments(pid).flatMap(QMPKeys.socketPath).flatMap { VMKeys.ours($0) ? $0 : nil }
    if let p { paths[pid] = p }
    return p
  }

  /// The process's arguments (KERN_PROCARGS2; our own user's processes only).
  static func arguments(_ pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 1 << 20 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    return ProcArgs.parse(Array(buf.prefix(size)))
  }

  /// A Unix socket owned by this user.
  static func ours(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid()
  }

  /// One key press (down, then up). False when the socket is gone, busy (no
  /// greeting within the timeout) or QEMU refused. Blocks up to ~1 s.
  static func press(_ qcode: String, socket path: String, timeout: Double = 0.4) -> Bool {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    withUnsafeMutableBytes(of: &addr.sun_path) { p in
      for (i, b) in bytes.enumerated() { p[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { return false }
    var pending = Data()
    // The next line that is not an event; nil on timeout, close or 64 KiB without a newline.
    func line() -> String? {
      while true {
        if let nl = pending.firstIndex(of: 10) {
          let l = String(decoding: pending[..<nl], as: UTF8.self)
          pending.removeSubrange(...nl)
          if QMPKeys.kind(l) != nil { return l }
          continue
        }
        guard pending.count < 65536 else { return nil }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &chunk, chunk.count, 0)
        guard n > 0 else { return nil }
        pending.append(contentsOf: chunk[..<n])
      }
    }
    guard let hello = line(), QMPKeys.kind(hello) == "greeting" else { return false }
    for c in QMPKeys.commands(qcode) {
      let out = Array((c + "\n").utf8)
      guard send(fd, out, out.count, 0) == out.count, let r = line(), QMPKeys.kind(r) == "ok" else { return false }
    }
    return true
  }

  /// A media key handed back to macOS (down and up), marked so the Bridge's
  /// own tap lets it through.
  static func repost(_ key: MediaKey) {
    for down in [true, false] {
      let data1 = key.rawValue << 16 | (down ? 0xA : 0xB) << 8
      guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                       subtype: 8, data1: data1, data2: -1)?.cgEvent else { continue }
      e.setIntegerValueField(.eventSourceUserData, value: marker)
      e.post(tap: .cghidEventTap)
    }
  }
}
