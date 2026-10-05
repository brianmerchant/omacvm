#!/bin/bash
# OmacVM.app while the VM sits idle, offline (no VM, no QEMU):
#  - the guest agent: one held connection serves every command, a late reply
#    is thrown away, a broken connection is replaced once;
#  - the Mac clipboard: polled fast only while the VM is the active app, at
#    once when it becomes active.
# The app's sources are compiled on their own with a small test main.
#   src/tests/app-idle.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/app/app/Sources/OmacVM
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
chmod 700 "$T"

cat > "$T/main.swift" <<'EOF'
import Darwin
import Foundation

// Model.swift has the app's HelperError; the test does not compile Model.swift.
enum HelperError: LocalizedError, Equatable {
    case io(String)
    var errorDescription: String? { if case .io(let d) = self { return d }; return nil }
}

var failed = false
func expect(_ what: String, _ ok: Bool) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failed = true }
}

/// A listening Unix socket in the test folder, served by `serve` on its own thread.
func listen(_ path: String) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in path.utf8.enumerated() { buf[i] = b } }
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    Darwin.listen(fd, 4)
    return fd
}

func readLine(_ fd: Int32) -> String? {
    var line = Data(), byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        if byte == 0x0A { return String(data: line, encoding: .utf8) }
        line.append(byte)
    }
    return nil
}

func reply(_ fd: Int32, _ s: String) { _ = (s + "\n").withCString { write(fd, $0, strlen($0)) } }

let dir = CommandLine.arguments[1]

// MARK: guest agent

do {
    let path = dir + "/qga"
    let server = listen(path)
    let lock = NSLock()
    var connections = 0
    var dropNext = false
    // Like qemu-ga behind QEMU's chardev: one client at a time, a reply per line;
    // "slow" answers after 3 s with a reply the client has stopped waiting for.
    Thread.detachNewThread {
        while true {
            let c = accept(server, nil, nil)
            if c < 0 { return }
            lock.lock(); connections += 1; lock.unlock()
            while let line = readLine(c) {
                lock.lock(); let drop = dropNext; dropNext = false; lock.unlock()
                if drop { break }
                if line.contains("slow") {
                    Thread.sleep(forTimeInterval: 3)
                    reply(c, "{\"return\":\"stale\"}")
                } else {
                    reply(c, "{\"return\":{}}")
                }
            }
            close(c)
        }
    }
    GuestAgent.hold(socketPath: path)
    expect("agent: setTime on the held connection", GuestAgent.setTime(socketPath: path))
    expect("agent: again", GuestAgent.setTime(socketPath: path))
    lock.lock(); expect("agent: one connection for both (got \(connections))", connections == 1); lock.unlock()

    let late = GuestAgent.execute(socketPath: path, "{\"execute\":\"slow\"}")
    expect("agent: no reply in 2 s gives an empty reply", late == "")
    Thread.sleep(forTimeInterval: 1.5)    // the late reply arrives meanwhile
    let fresh = GuestAgent.execute(socketPath: path, "{\"execute\":\"guest-set-time\"}")
    expect("agent: the late reply is thrown away (got \(fresh ?? "nil"))", fresh?.contains("{}") == true)

    lock.lock(); dropNext = true; lock.unlock()
    expect("agent: a dropped connection is replaced once", GuestAgent.setTime(socketPath: path))
    lock.lock(); expect("agent: two connections now (got \(connections))", connections == 2); lock.unlock()

    GuestAgent.release(socketPath: path)
    expect("agent: after release, a connection of its own", GuestAgent.setTime(socketPath: path))
    close(server)
}

// MARK: clipboard poll

final class CountingPasteboard: HostPasteboardProviding {
    private let lock = NSLock()
    private var n = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return n }
    var changeCount: Int { lock.lock(); n += 1; lock.unlock(); return 1 }
    func read() -> ClipboardMessage? { nil }
    func write(_ message: ClipboardMessage) {}
}

do {
    let path = dir + "/clip"
    let server = listen(path)
    Thread.detachNewThread { _ = accept(server, nil, nil) }   // the guest side, silent
    let pb = CountingPasteboard()
    let bridge = try! NativeClipboardBridge(socketPath: path, pasteboard: pb)
    Thread.detachNewThread { try? bridge.run() }
    Thread.sleep(forTimeInterval: 0.2)
    var start = pb.reads
    Thread.sleep(forTimeInterval: 1.1)
    expect("clipboard: active VM, 4 polls a second (got \(pb.reads - start) in 1.1 s)", pb.reads - start >= 3)
    bridge.setVMActive(false)
    Thread.sleep(forTimeInterval: 0.3)
    start = pb.reads
    Thread.sleep(forTimeInterval: 2.0)
    expect("clipboard: VM in the background, no poll in 2 s (got \(pb.reads - start))", pb.reads - start == 0)
    start = pb.reads
    bridge.setVMActive(true)
    Thread.sleep(forTimeInterval: 0.1)
    expect("clipboard: one poll right when the VM becomes active (got \(pb.reads - start))", pb.reads - start >= 1)
    bridge.stop()
    close(server)
}

exit(failed ? 1 : 0)
EOF

swiftc -module-cache-path "$T/mc" -o "$T/idle" "$S/GuestAgent.swift" "$S/NativeClipboardBridge.swift" \
  "$S/NativeBridgeSocket.swift" "$T/main.swift" 2>&1 ||
  { echo "FAIL the agent and clipboard sources do not compile on their own"; exit 1; }
"$T/idle" "$T"
