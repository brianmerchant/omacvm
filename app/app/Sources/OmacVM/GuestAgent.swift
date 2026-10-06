import Darwin
import Foundation

/// The QEMU guest agent in the VM (virtio-serial). Only what the launcher needs.
///
/// The launcher stays connected to the agent's port while the VM runs: with
/// nobody on the Mac side of a virtio-serial port, qemu-ga in the VM finds it
/// closed and looks again ten times a second (an idle VM's CPUs woke for it).
/// One connection, one command at a time (`lock`).
enum GuestAgent {
    private static let lock = NSLock()
    /// The longest reply read (guest-exec-status with 4 KB of output is far shorter).
    private static let maxReply = 64 * 1024
    private static var held: (path: String, fd: Int32)?

    /// Connects to the agent's socket and keeps the connection (QEMU accepts
    /// one client). Tries for a while: the socket appears a moment after QEMU
    /// starts. Off the main thread.
    static func hold(socketPath: String) {
        for _ in 0..<50 {
            lock.lock()
            if held?.path == socketPath {
                lock.unlock()
                return
            }
            if let fd = connect(socketPath) {
                held = (socketPath, fd)
                lock.unlock()
                return
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Lets go of the connection (QEMU ended).
    static func release(socketPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if let h = held, h.path == socketPath {
            close(h.fd)
            held = nil
        }
    }

    /// Asks the guest to power off. Does nothing if no agent answers.
    static func shutdown(socketPath: String) {
        _ = execute(socketPath: socketPath, "{\"execute\":\"guest-shutdown\",\"arguments\":{\"mode\":\"powerdown\"}}")
    }

    /// Sets the guest clock to the Mac's. The VM's clock stands still while
    /// the Mac sleeps; Linux would only catch up at its next time sync.
    @discardableResult
    static func setTime(socketPath: String) -> Bool {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let ns = Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec)
        let reply = execute(socketPath: socketPath, "{\"execute\":\"guest-set-time\",\"arguments\":{\"time\":\(ns)}}")
        return reply?.contains("\"return\"") == true
    }

    /// Starts a program in the VM as root (guest-exec) without waiting for it.
    /// Arguments are passed as they are, no shell in between.
    @discardableResult
    static func run(socketPath: String, _ path: String, _ args: [String]) -> Bool {
        let body: [String: Any] = ["execute": "guest-exec", "arguments": ["path": path, "arg": args]]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let command = String(data: json, encoding: .utf8) else { return false }
        return execute(socketPath: socketPath, command)?.contains("\"return\"") == true
    }

    /// What `runAndWait` saw.
    enum Outcome: Equatable {
        case noAgent                 // no agent answered (the VM is starting, or has none)
        case refused(String)         // the agent did not start it: its error, shortened
        case running                 // still running when the wait ended
        case exited(Int32, String)   // its exit code and the start of its output
    }

    /// Runs a program in the VM as root (guest-exec, its output captured) and
    /// waits up to `seconds` for it to end. The guest is untrusted: only the
    /// fields named here are read, numbers within range, at most 4 KB of output.
    static func runAndWait(socketPath: String, _ path: String, _ args: [String], seconds: Double) -> Outcome {
        let body: [String: Any] = ["execute": "guest-exec",
                                   "arguments": ["path": path, "arg": args, "capture-output": true]]
        guard let json = try? JSONSerialization.data(withJSONObject: body),
              let command = String(data: json, encoding: .utf8),
              let started = object(execute(socketPath: socketPath, command)) else { return .noAgent }
        if let error = started["error"] as? [String: Any] {
            return .refused(String(String(describing: error["desc"] ?? "error").prefix(200)))
        }
        guard let ret = started["return"] as? [String: Any], let pid = ret["pid"] as? Int,
              pid > 0, pid <= Int(Int32.max) else { return .noAgent }
        let status = "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":\(pid)}}"
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            guard let st = object(execute(socketPath: socketPath, status))?["return"] as? [String: Any],
                  st["exited"] as? Bool == true else { continue }
            let code = (st["exitcode"] as? Int).map { Int32(clamping: $0) } ?? -1   // none: ended by a signal
            var out = ""
            if let b64 = st["out-data"] as? String, let data = Data(base64Encoded: String(b64.prefix(8192))) {
                out = String(decoding: data.prefix(4096), as: UTF8.self)
            }
            return .exited(code, out)
        }
        return .running
    }

    private static func object(_ reply: String?) -> [String: Any]? {
        guard let reply, let data = reply.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sends one command and waits up to two seconds for its one-line reply.
    /// On the held connection when there is one (a broken one is replaced
    /// once), else on a connection of its own.
    static func execute(socketPath: String, _ command: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let h = held, h.path == socketPath {
            if let reply = exchange(h.fd, command) { return reply }
            close(h.fd)
            held = nil
            guard let fd = connect(socketPath) else { return nil }
            held = (socketPath, fd)
            return exchange(fd, command)
        }
        guard let fd = connect(socketPath) else { return nil }
        defer { close(fd) }
        return exchange(fd, command)
    }

    private static func connect(_ socketPath: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(fd); return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// One command, one reply line. A late reply to an earlier command (it
    /// timed out) is thrown away first. nil: the connection is broken.
    private static func exchange(_ fd: Int32, _ command: String) -> String? {
        var chunk = [UInt8](repeating: 0, count: 4096)
        var stale = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Darwin.poll(&stale, 1, 0) > 0, stale.revents & Int16(POLLIN) != 0 {
            if read(fd, &chunk, chunk.count) <= 0 { return nil }
            stale.revents = 0
        }
        let line = command + "\n"
        guard line.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return nil }
        var reply = Data()
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            if n < 0 { break }          // no reply in time: the connection stays
            reply.append(contentsOf: chunk[0..<n])
            if reply.count > maxReply { return nil }   // no reply is this long: a new connection
        }
        return String(data: reply, encoding: .utf8) ?? ""
    }
}
