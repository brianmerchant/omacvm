import Darwin
import Foundation

/// Touch ID for this app's VMs (docs/adr/0041): the virtio port
/// org.omacvm.auth carries the VM's PAM client's request to OmacVM Bridge,
/// which shows the Mac's Touch ID dialog, and the Bridge's signed answer back.
/// The port is root's alone in the VM (udev, 0600) and is there only when
/// the VM's features say touch-id=on at its start (MacLinks.touchID).
///
/// Lines, one JSON object each. From the VM:
///   {"op":"touchid","id":N,"auth":"1 T N SIG","proto":1,"body":"<base64>"}
///   {"op":"ping","id":N}      every half second while it waits
///   {"op":"cancel","id":N}    it gave up (deadline, Ctrl+C on the way out)
/// N is the request's nonce (32 hex digits), the same as in the signature.
/// To the VM: {"id":N,"status":S,"answer":"<X-OmacVM-Answer>","body":"<base64>"}
/// with the Bridge's body byte for byte (the answer's signature covers it);
/// status 0: the Bridge did not answer.
///
/// The app checks nothing about the signature: the Bridge does, with the
/// VM's Touch ID key, and the VM checks the answer. The app adds the Bridge
/// token and the relay key and names the VM (a guest cannot name another).
///
/// QEMU's socket does not say when the VM closes the port, so the client
/// pings: no ping for `pingTimeout`, a cancel, or a new request (the port
/// has one opener at a time, so the old client is gone) drops the Bridge
/// connection, and the Bridge closes the dialog (its peerGone).
public final class AuthRelay: @unchecked Sendable {
    public static let maximumLineBytes = 4096
    public static let maximumBodyBytes = 1024

    public struct Request: Equatable {
        public let id: String, auth: String, proto: Int, body: Data
    }

    public enum Line: Equatable {
        case request(Request)
        case ping(String)
        case cancel(String)
    }

    static func isHex(_ s: String, count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// One line from the VM, or nil (not one of ours: dropped).
    public static func parse(_ line: Data) -> Line? {
        guard line.count <= maximumLineBytes,
              let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let op = o["op"] as? String, let id = o["id"] as? String, isHex(id, count: 32) else { return nil }
        switch op {
        case "ping": return .ping(id)
        case "cancel": return .cancel(id)
        case "touchid":
            // "1 <time> <nonce> <hmac>", the nonce the line's id.
            guard let auth = o["auth"] as? String else { return nil }
            let f = auth.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 4, f[0] == "1", f[1].utf8.count <= 12, Int64(f[1]) != nil, f[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  f[2] == id, isHex(f[3], count: 64) else { return nil }
            guard let b64 = o["body"] as? String, let body = Data(base64Encoded: b64), !body.isEmpty, body.count <= maximumBodyBytes
            else { return nil }
            let proto = (o["proto"] as? Int).map { min(max($0, 0), 99) } ?? 1
            return .request(Request(id: id, auth: auth, proto: proto, body: body))
        default: return nil
        }
    }

    /// The Bridge's answer: status, its X-OmacVM-Answer and the body as sent.
    public struct Answer: Equatable {
        public let status: Int, signature: String, body: Data
        public init(status: Int, signature: String, body: Data) { self.status = status; self.signature = signature; self.body = body }
    }

    /// One HTTP/1.1 request on the Bridge's relay socket.
    public static func httpRequest(_ r: Request, headers: [(String, String)]) -> Data {
        BridgeHTTP.request(method: "POST", path: "/omacvm/touchid",
                           headers: headers + [("X-OmacVM-Auth", r.auth), ("X-OmacVM-Proto", String(r.proto)), ("Content-Type", "application/json")],
                           body: r.body)
    }

    /// The Bridge's answer, or nil (none, cut short, not HTTP, too big).
    public static func parseResponse(_ data: Data) -> Answer? {
        guard let r = BridgeHTTP.parse(data), r.body.count <= 4096 else { return nil }
        var signature = r.headers["x-omacvm-answer"] ?? ""
        if signature.utf8.count > 128 || !signature.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) { signature = "" }
        return Answer(status: r.status, signature: signature, body: r.body)
    }

    /// The line to the VM; nil answer: status 0.
    public static func answerLine(id: String, _ a: Answer?) -> Data {
        var o: [String: Any] = ["id": id, "status": a?.status ?? 0]
        if let a {
            o["answer"] = a.signature
            o["body"] = a.body.base64EncodedString()
        }
        var d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        d.append(0x0A)
        return d
    }

    // MARK: The relay
    //
    // Threads: run() reads the VM's lines on its own thread and owns the
    // guest socket (it closes it when it returns). Each request to the Bridge
    // runs on one exchange thread; `slot` lets only one exist at a time.
    // Answers to the VM are written under `writeLock`, never longer than
    // `writeTimeout`.

    private let guest: Int32
    private let connectBridge: () -> Int32?
    private let headers: () -> [(String, String)]?
    private let log: (String) -> Void
    public var pingTimeout: TimeInterval = 3
    /// The Bridge's dialog waits 30 s; the client gives up at 40 s.
    public var answerTimeout: TimeInterval = 45
    /// A VM that does not take its answer within this is dropped: its port's
    /// socket is shut down, and the app connects to it again.
    public var writeTimeout: TimeInterval = 2
    /// Requests to the Bridge per minute; more get status 0 (the password).
    /// The Bridge has its own growing pauses after misses; this one keeps a
    /// VM from making threads and connections on the Mac.
    public var requestsPerMinute = 20
    /// How long a new request waits for the one before it to end (dropped, it
    /// ends at once).
    public var handoverTimeout: TimeInterval = 1
    private let lock = NSLock()
    private var current: (id: String, fd: Int32, lastPing: Date, cancelled: Bool)?
    private var stopped = false
    private let slot = DispatchSemaphore(value: 1)
    private var recent: [Date] = []   // run()'s thread only
    private var saidLimit = false     // run()'s thread only
    private let writeLock = NSLock()
    private var closed = false   // the guest's socket (under writeLock: no write or shutdown after the close)

    /// `guest`: the connected chardev socket; run() closes it. `connectBridge`:
    /// a connected socket to the Bridge, or nil. `headers`: the app's own
    /// headers (token, relay key, VM name), or nil when the Bridge is not set up.
    public init(guest: Int32, connectBridge: @escaping () -> Int32?, headers: @escaping () -> [(String, String)]?,
                log: @escaping (String) -> Void = { _ in }) {
        self.guest = guest
        self.connectBridge = connectBridge
        self.headers = headers
        self.log = log
    }

    /// Reads the VM's lines until the port's socket closes (or stop()), then
    /// closes it.
    public func run() throws {
        var line = Data(), skipping = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        defer {
            lock.lock(); stopped = true; lock.unlock()
            drop(nil)
            writeLock.lock(); closed = true; Darwin.close(guest); writeLock.unlock()
        }
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(guest, $0.baseAddress, $0.count) }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    if !skipping {
                        line.append(contentsOf: chunk[start..<index])
                        if let l = Self.parse(line) { handle(l) }
                    }
                    line.removeAll(keepingCapacity: true)
                    skipping = false
                    start = index + 1
                }
                if !skipping {
                    line.append(contentsOf: chunk[start..<count])
                    if line.count > Self.maximumLineBytes { line.removeAll(); skipping = true }
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "cannot read the guest auth port"])
            }
        }
    }

    /// Ends run() from another thread. Only shuts the socket down: run() may
    /// be in a read on it, so run() closes it.
    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        drop(nil)
        writeLock.lock(); defer { writeLock.unlock() }
        if !closed { Darwin.shutdown(guest, SHUT_RDWR) }
    }

    /// Drops the request in flight (`id` nil: any), so the Bridge closes its dialog.
    private func drop(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let c = current, id == nil || c.id == id else { return }
        current?.cancelled = true
        Darwin.shutdown(c.fd, SHUT_RDWR)
    }

    private func handle(_ l: Line) {
        switch l {
        case .ping(let id):
            lock.lock()
            if current?.id == id { current?.lastPing = Date() }
            lock.unlock()
        case .cancel(let id):
            drop(id)
        case .request(let r):
            drop(nil)   // one opener at a time: the client of the old one is gone
            // A dropped exchange ends at once; one at a time, so a VM that
            // floods requests never piles up threads and connections.
            guard slot.wait(timeout: .now() + handoverTimeout) == .success else {
                return answer(r.id, nil, note: "Touch ID: the request before is still ending, this one gets the password")
            }
            var handed = false
            defer { if !handed { slot.signal() } }
            let now = Date()
            recent.removeAll { now.timeIntervalSince($0) >= 60 }
            guard recent.count < requestsPerMinute else {
                let note = saidLimit ? nil : "Touch ID: more than \(requestsPerMinute) requests a minute from this VM, the password for now"
                saidLimit = true
                return answer(r.id, nil, note: note)
            }
            saidLimit = false
            recent.append(now)
            guard let h = headers() else {
                return answer(r.id, nil, note: "OmacVM Bridge is not set up on this Mac (or is older)")
            }
            guard let fd = connectBridge() else { return answer(r.id, nil, note: "OmacVM Bridge does not answer") }
            lock.lock()
            if stopped { lock.unlock(); Darwin.close(fd); return }
            current = (r.id, fd, Date(), false)
            lock.unlock()
            handed = true
            Thread.detachNewThread { [self] in
                defer { slot.signal() }
                exchange(r, fd: fd, headers: h)
            }
        }
    }

    /// One line to the VM. Never blocks longer than `writeTimeout`: a VM that
    /// does not read is dropped (its socket shut down, run() ends).
    private func answer(_ id: String, _ a: Answer?, note: String? = nil) {
        if let note { log(note) }
        writeLock.lock(); defer { writeLock.unlock() }
        guard !closed else { return }
        let d = Self.answerLine(id: id, a)
        let deadline = Date().addingTimeInterval(writeTimeout)
        // SO_SNDTIMEO, not MSG_DONTWAIT: macOS blocks a Unix socket's send
        // larger than the free buffer even with MSG_DONTWAIT. Only answer()
        // writes this socket, so the option is ours to set.
        let sent = d.withUnsafeBytes { b -> Bool in
            var off = 0
            while off < b.count {
                let left = deadline.timeIntervalSinceNow
                guard left > 0 else { return false }
                var tv = timeval(tv_sec: Int(left), tv_usec: Int32((left - left.rounded(.down)) * 1_000_000))
                setsockopt(guest, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let n = Darwin.write(guest, b.baseAddress!.advanced(by: off), b.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                return false
            }
            return true
        }
        if !sent {
            log("Touch ID: the VM does not take its answers, its port is dropped")
            Darwin.shutdown(guest, SHUT_RDWR)
        }
    }

    /// The request to the Bridge and its answer; the VM's pings keep it up.
    private func exchange(_ r: Request, fd: Int32, headers: [(String, String)]) {
        defer {
            lock.lock()
            if current?.fd == fd { current = nil }
            lock.unlock()
            Darwin.close(fd)
        }
        func gone() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let c = current, c.fd == fd else { return true }
            return c.cancelled || Date().timeIntervalSince(c.lastPing) > pingTimeout
        }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let request = Self.httpRequest(r, headers: headers)
        let wrote = request.withUnsafeBytes { b -> Bool in
            var off = 0
            while off < b.count {
                let n = Darwin.write(fd, b.baseAddress!.advanced(by: off), b.count - off)
                if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        guard wrote else { return answer(r.id, nil, note: "OmacVM Bridge does not answer") }
        let deadline = Date().addingTimeInterval(answerTimeout)
        var data = Data(), chunk = [UInt8](repeating: 0, count: 8192)
        while data.count <= 65536 {
            if gone() {
                log("Touch ID: the VM's client went away, the dialog is closed")
                return   // nobody to answer
            }
            if Date() >= deadline { return answer(r.id, nil, note: "OmacVM Bridge did not answer in time") }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 250)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { data.append(contentsOf: chunk[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            break   // the Bridge closed: the whole answer is here
        }
        if gone() { return }
        answer(r.id, Self.parseResponse(data))
    }
}
