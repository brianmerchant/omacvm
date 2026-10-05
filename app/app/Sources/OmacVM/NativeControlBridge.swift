import Darwin
import Foundation

/// The control centre for this app's VMs (docs/adr/0031): the virtio port
/// org.omacvm.control carries the VM's requests, one JSON line each
/// ({"id", "method", "path", "body", "proto", "version"}), and the answers
/// back ({"id", "status", "body"}). Each request goes on to OmacVM Bridge on
/// this Mac, which decides what is allowed (the same fixed list as for the
/// other routes). The app names the VM: it knows whose port this is, and a
/// guest cannot name another VM (its guests all reach the Mac from
/// 127.0.0.1, so the Bridge cannot tell them apart by address). The relay key
/// proves to the Bridge that the app sent it; no VM ever gets that key.
/// The requests go on the Bridge's relay socket (omacvm-bridge/relay.sock,
/// only this Mac user can open it), so guests that crowd 127.0.0.1 cannot
/// take the relay's places. When the socket cannot be used (an older Bridge,
/// the Bridge not running, the folder not 0700) they go on 127.0.0.1.
///
/// The guest is untrusted: lines over 8 KB are dropped, only GET and POST to
/// /omacvm/... with a JSON object body go on, at most 4 requests at a time.
/// Status 0 in an answer: the Bridge did not answer.
final class NativeControlBridge: @unchecked Sendable {
    static let maximumLineBytes = 8192
    /// The Bridge's port (OMACVM_BRIDGE_PORT as for the Bridge itself: tests).
    static let bridgePort = Int(ProcessInfo.processInfo.environment["OMACVM_BRIDGE_PORT"] ?? "").flatMap { (1...65535).contains($0) ? $0 : nil } ?? 47831

    private let descriptor: Int32
    private let vmName: String
    private let writeLock = NSLock()
    private let slots = DispatchSemaphore(value: 4)
    private let stopLock = NSLock()
    private var stopped = false

    init(socketPath: String, vmName: String) throws {
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "control port")
        self.vmName = vmName
    }

    deinit { stop() }

    func run() throws {
        var line = Data(), skipping = false
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    if !skipping {
                        line.append(contentsOf: chunk[start..<index])
                        handle(line)
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
                throw HelperError.io("cannot read the guest control port")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else { stopLock.unlock(); return }
        stopped = true
        stopLock.unlock()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    /// A request the app passes on, or nil (dropped: not one of ours).
    struct Request: Equatable {
        let id: String, method: String, path: String, body: Data?, proto: Int, version: String
    }

    static func parse(_ line: Data) -> Request? {
        guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = o["id"] as? String, id.count <= 32, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let method = o["method"] as? String, method == "GET" || method == "POST",
              let path = o["path"] as? String, path.hasPrefix("/omacvm/"), path.utf8.count <= 128,
              path.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { return nil }
        var body: Data?
        if let b = o["body"], !(b is NSNull) {
            guard b is [String: Any], let d = try? JSONSerialization.data(withJSONObject: b), d.count <= 4096 else { return nil }
            body = d
        }
        let proto = (o["proto"] as? Int).map { min(max($0, 0), 99) } ?? 1
        var version = (o["version"] as? String) ?? ""
        if version.count > 32 || !version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) { version = "" }
        return Request(id: id, method: method, path: path, body: body, proto: proto, version: version)
    }

    private func handle(_ line: Data) {
        guard let r = Self.parse(line) else { return }
        slots.wait()   // in step with the reads: a VM that floods waits for its answers
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { slots.signal() }
            let (status, body) = relay(r)
            var answer = Data((try? JSONSerialization.data(withJSONObject: ["id": r.id, "status": status, "body": body])) ?? Data("{}".utf8))
            answer.append(0x0A)
            writeLock.lock(); defer { writeLock.unlock() }
            do { try NativeBridgeSocket.writeAll(answer, to: descriptor, label: "control") }
            catch { fputs("[control] \(error.localizedDescription)\n", stderr) }
        }
    }

    private static func secret(_ name: String) -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/omacvm-bridge/\(name)").path
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 32 ? t : nil
    }

    /// The Bridge's relay socket (OMACVM_BRIDGE_RELAY_SOCKET as for the Bridge itself: tests).
    static let relaySocketPath = ProcessInfo.processInfo.environment["OMACVM_BRIDGE_RELAY_SOCKET"]
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/omacvm-bridge/relay.sock").path
    static let timeout: TimeInterval = 75
    private let fallbackLock = NSLock()
    private var saidFallback = false

    /// The request to the Bridge, with the app's headers only.
    private func relay(_ r: Request) -> (Int, [String: Any]) {
        guard let token = Self.secret("token"), let relayKey = Self.secret("relay-key") else {
            return (0, ["error": "OmacVM Bridge is not set up on this Mac (or is older): omacvm update on the Mac"])
        }
        var headers: [(String, String)] = [
            ("Authorization", "Bearer " + token),
            ("X-OmacVM-Relay", relayKey),
            ("X-OmacVM-App-VM", Data(vmName.utf8).base64EncodedString()),
            ("X-OmacVM-Proto", String(r.proto)),
        ]
        if !r.version.isEmpty { headers.append(("X-OmacVM-Version", r.version)) }
        if r.body != nil { headers.append(("Content-Type", "application/json")) }
        // Once connected, the answer comes from there: a request is never sent
        // twice (a job must not start twice).
        if let fd = try? NativeBridgeSocket.connectSecure(path: Self.relaySocketPath, label: "Bridge relay") {
            defer { Darwin.close(fd) }
            return Self.exchange(fd, Self.httpRequest(method: r.method, path: r.path, headers: headers, body: r.body))
        }
        fallbackLock.lock()
        if !saidFallback {
            saidFallback = true
            fputs("[control] OmacVM Bridge's relay socket cannot be used (older Bridge, not running, or folder not 0700): 127.0.0.1\n", stderr)
        }
        fallbackLock.unlock()
        guard let url = URL(string: "http://127.0.0.1:\(Self.bridgePort)\(r.path)") else {
            return (0, ["error": "OmacVM Bridge does not answer on this Mac"])
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        req.httpMethod = r.method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = r.body { req.httpBody = b }
        var result: (Int, [String: Any]) = (0, ["error": "OmacVM Bridge does not answer on this Mac"])
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let h = response as? HTTPURLResponse {
                let o = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
                result = (h.statusCode, o)
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    /// One HTTP/1.1 request; the Bridge answers with Content-Length and closes.
    static func httpRequest(method: String, path: String, headers: [(String, String)], body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: omacvm-bridge\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    /// Status and JSON body of the Bridge's answer, or nil (not one).
    static func parseResponse(_ data: Data) -> (Int, [String: Any])? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2, first[0].hasPrefix("HTTP/1."), let status = Int(first[1]), (100...599).contains(status) else { return nil }
        var body = data[end.upperBound...]
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length",
               let n = Int(kv[1].trimmingCharacters(in: .whitespaces)), n >= 0 {
                guard body.count >= n else { return nil }   // cut short
                body = body.prefix(n)
            }
        }
        let o = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] ?? [:]
        return (status, o)
    }

    /// Sends the request on the relay socket and reads the answer until the
    /// Bridge closes (at most 1 MB, `timeout` in all).
    static func exchange(_ fd: Int32, _ request: Data) -> (Int, [String: Any]) {
        let failed = (0, ["error": "OmacVM Bridge does not answer on this Mac"] as [String: Any])
        let deadline = Date().addingTimeInterval(timeout)
        func setTimeout(_ option: Int32) {
            let left = max(0.001, deadline.timeIntervalSinceNow)
            var tv = timeval(tv_sec: Int(left), tv_usec: Int32((left - left.rounded(.down)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        setTimeout(SO_SNDTIMEO)
        guard (try? NativeBridgeSocket.writeAll(request, to: fd, label: "Bridge relay")) != nil else { return failed }
        var answer = Data(), chunk = [UInt8](repeating: 0, count: 16384)
        while answer.count <= 1 << 20, deadline.timeIntervalSinceNow > 0 {
            setTimeout(SO_RCVTIMEO)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 { answer.append(contentsOf: chunk[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            break
        }
        return parseResponse(answer) ?? failed
    }
}
