// End-to-end test of vm-keys.swift against a real QEMU (test-vm-keys.sh starts
// it headless and paused: no window, no guest). The QMP socket is found from
// the QEMU process's own command line, as for the VM in front; QEMU's trace
// shows the keys it got.
//   vmkeys-test <qemu pid> <expected socket>
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed += 1 }
}
let a = CommandLine.arguments
let pid = pid_t(a[1])!, want = a[2]
let keys = VMKeys()
let path = keys.socket(for: pid)
check(path == want, "the QMP socket from QEMU's command line (\(path ?? "none"))")
check(VMKeys.ours(want), "the socket is this user's")
check(keys.socket(for: getpid()) == nil, "a process without -qmp: none")
guard let path else { exit(1) }
// QEMU was started paused (as OmacVM.app pauses a VM while the Mac sleeps):
// QEMU refuses keys then, so the key goes to macOS.
check(!VMKeys.press("volumeup", socket: path), "the VM paused: QEMU refuses, false")
func raw(_ cmds: [String]) {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in Array(path.utf8).enumerated() { p[i] = b } }
  _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  for c in cmds { _ = (c + "\n").withCString { send(fd, $0, strlen($0), 0) }; usleep(100_000) }
  close(fd)
}
raw([#"{"execute":"qmp_capabilities"}"#, #"{"execute":"cont"}"#])
usleep(200_000)
var t = Date()
check(VMKeys.press("volumeup", socket: path), "volume up typed into the VM")
check(Date().timeIntervalSince(t) < 0.5, "... at once (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
check(VMKeys.press("audioplay", socket: path), "play/pause typed into the VM")
check(VMKeys.press("audionext", socket: path) && VMKeys.press("audioprev", socket: path) && VMKeys.press("audiomute", socket: path),
      "next, previous, mute typed")
check(!VMKeys.press("nosuchkey", socket: path), "a key QEMU does not know: refused, false")
// Busy: QEMU serves one QMP client at a time (OmacVM.app holds it during sleep).
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in Array(path.utf8).enumerated() { p[i] = b } }
_ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
usleep(200_000)
t = Date()
check(!VMKeys.press("volumeup", socket: path), "socket busy (another client): false, so the key goes to macOS")
check(Date().timeIntervalSince(t) < 1.0, "... within the timeout (\(Int(Date().timeIntervalSince(t) * 1000)) ms)")
close(fd)
usleep(200_000)
check(VMKeys.press("volumedown", socket: path), "free again: typed")
check(!VMKeys.press("volumeup", socket: path + ".gone"), "no socket: false")
exit(failed > 0 ? 1 : 0)
