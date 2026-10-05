import Darwin
import Foundation

/// The QEMU guest agent in the VM (virtio-serial). Only what the launcher needs.
enum GuestAgent {
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

    /// Sends one command and waits up to two seconds for its one-line reply,
    /// so no reply is left behind for the next caller.
    static func execute(socketPath: String, _ command: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { return nil }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let line = command + "\n"
        guard line.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return nil }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            reply.append(contentsOf: chunk[0..<n])
        }
        return String(data: reply, encoding: .utf8)
    }
}
