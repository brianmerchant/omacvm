// Touch ID's port relay for the app's VMs (OmacVMAuth), without a VM, a
// Bridge or a Touch ID dialog: the guest's port and the Bridge are socket
// pairs here.
//   cd app/app && swift run auth-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Darwin
import Foundation
import OmacVMAuth

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias R = AuthRelay
let nonce = String(repeating: "ab", count: 16)
let sig = String(repeating: "0f", count: 32)
let body = Data(#"{"kind":"sudo","user":"vincent","detail":"true","tty":"pts/0"}"#.utf8)
func json(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }
func requestLine(id: String = nonce, auth: String? = nil, body b: Data = body) -> [String: Any] {
    ["op": "touchid", "id": id, "auth": auth ?? "1 1760000000 \(id) \(sig)", "proto": 1, "body": b.base64EncodedString()]
}

// MARK: Lines from the VM

if case .request(let r)? = R.parse(json(requestLine())) {
    expect(r.id == nonce && r.body == body && r.proto == 1 && r.auth.hasPrefix("1 1760000000 "), "request: parsed")
} else { expect(false, "request: parsed") }
expect(R.parse(json(["op": "ping", "id": nonce])) == .ping(nonce), "ping")
expect(R.parse(json(["op": "cancel", "id": nonce])) == .cancel(nonce), "cancel")
expect(R.parse(json(["op": "ping", "id": "AB" + String(nonce.dropFirst(2))])) == nil, "id: lower-case hex only")
expect(R.parse(json(["op": "ping", "id": "abc"])) == nil, "id: 32 digits")
expect(R.parse(json(["op": "other", "id": nonce])) == nil, "unknown op dropped")
expect(R.parse(Data("not json".utf8)) == nil, "not JSON dropped")
expect(R.parse(Data("[1]".utf8)) == nil, "not an object dropped")
let other = String(repeating: "cd", count: 16)
expect(R.parse(json(requestLine(auth: "1 1760000000 \(other) \(sig)"))) == nil, "auth's nonce must be the id")
expect(R.parse(json(requestLine(auth: "2 1760000000 \(nonce) \(sig)"))) == nil, "auth: version 1 only")
expect(R.parse(json(requestLine(auth: "1 -5 \(nonce) \(sig)"))) == nil, "auth: time digits only")
expect(R.parse(json(requestLine(auth: "1 1760000000 \(nonce) \(sig)\r\nX-Evil: 1"))) == nil, "auth: no header injection")
expect(R.parse(json(requestLine(auth: "1 1760000000 \(nonce) xyz"))) == nil, "auth: 64 hex digits")
expect(R.parse(json(requestLine(body: Data(repeating: 0x41, count: 1025)))) == nil, "body over 1 KB dropped")
expect(R.parse(json(requestLine(body: Data()))) == nil, "empty body dropped")
var badB64 = requestLine(); badB64["body"] = "%%%"
expect(R.parse(json(badB64)) == nil, "body not base64 dropped")
var big = requestLine(); big["pad"] = String(repeating: "x", count: 5000)
expect(R.parse(json(big)) == nil, "line over 4 KB dropped")

// MARK: To the Bridge and back

if case .request(let r)? = R.parse(json(requestLine())) {
    let h = String(decoding: R.httpRequest(r, headers: [("Authorization", "Bearer T"), ("X-OmacVM-Relay", "K"), ("X-OmacVM-App-VM", "Vk0=")]), as: UTF8.self)
    expect(h.hasPrefix("POST /omacvm/touchid HTTP/1.1\r\n"), "http: POST /omacvm/touchid")
    expect(h.contains("\r\nX-OmacVM-Auth: \(r.auth)\r\n") && h.contains("\r\nX-OmacVM-Relay: K\r\n") && h.contains("\r\nX-OmacVM-App-VM: Vk0=\r\n"),
           "http: the guest's signature and the app's headers")
    expect(h.contains("\r\nContent-Length: \(body.count)\r\n") && h.hasSuffix("\r\n\r\n" + String(decoding: body, as: UTF8.self)), "http: the body as sent")
}
let answerBody = Data("{\"result\":\"yes\"}\n".utf8)
let resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-OmacVM-Answer: \(sig)\r\nContent-Length: \(answerBody.count)\r\n\r\n".utf8) + answerBody
expect(R.parseResponse(resp) == R.Answer(status: 200, signature: sig, body: answerBody), "response: status, signature, body byte for byte")
expect(R.parseResponse(resp.prefix(resp.count - 3)) == nil, "response cut short: none")
expect(R.parseResponse(Data("garbage".utf8)) == nil, "not HTTP: none")
expect(R.parseResponse(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\n\r\n{}".utf8)) == R.Answer(status: 403, signature: "", body: Data("{}".utf8)),
       "unsigned 403 passed on (the VM decides)")
let line = R.answerLine(id: nonce, R.Answer(status: 200, signature: sig, body: answerBody))
let lo = try! JSONSerialization.jsonObject(with: line.dropLast()) as! [String: Any]
expect(line.last == 0x0A && lo["id"] as? String == nonce && lo["status"] as? Int == 200 && lo["answer"] as? String == sig
       && Data(base64Encoded: lo["body"] as! String) == answerBody, "answer line: one line, body base64")
let none = try! JSONSerialization.jsonObject(with: R.answerLine(id: nonce, nil).dropLast()) as! [String: Any]
expect(none["status"] as? Int == 0 && none["body"] == nil, "no answer: status 0")

// MARK: The relay, end to end (socket pairs for the port and the Bridge)

func pair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    var one: Int32 = 1
    for f in fds { setsockopt(f, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) }
    return (fds[0], fds[1])
}
func send(_ fd: Int32, _ o: [String: Any]) {
    var d = json(o); d.append(0x0A)
    _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}
/// Reads until the peer closes or `timeout`; returns the bytes and whether it closed.
func readAll(_ fd: Int32, timeout: Double, untilNewline: Bool = false, untilHeaders: Bool = false) -> (Data, Bool) {
    var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 50) > 0 else { continue }
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return (out, true) }
        out.append(contentsOf: buf[0..<n])
        if untilNewline, out.last == 0x0A { return (out, false) }
        if untilHeaders, let e = out.range(of: Data("\r\n\r\n".utf8)), out.count >= e.upperBound + body.count { return (out, false) }
    }
    return (out, false)
}

final class FakeBridge: @unchecked Sendable {
    let lock = NSLock()
    var requests: [Data] = []
    var closedEarly: [Bool] = []
    var answer: Data? = resp   // nil: never answers (a dialog up)
    var connects = 0
    func connect() -> Int32? {
        let (a, b) = pair()
        lock.lock(); connects += 1; lock.unlock()
        Thread.detachNewThread { [self] in
            let (req, _) = readAll(b, timeout: 5, untilHeaders: true)
            lock.lock(); requests.append(req); let a = answer; lock.unlock()
            if let a {
                _ = a.withUnsafeBytes { write(b, $0.baseAddress, $0.count) }
            } else {
                let (_, closed) = readAll(b, timeout: 8)   // the dialog waits: until the relay drops it
                lock.lock(); closedEarly.append(closed); lock.unlock()
            }
            close(b)
        }
        return a
    }
    func wait(_ f: () -> Bool, _ t: Double = 5) -> Bool {
        let end = Date().addingTimeInterval(t)
        while Date() < end { lock.lock(); let ok = f(); lock.unlock(); if ok { return true }; usleep(20_000) }
        return false
    }
}

let headers: () -> [(String, String)]? = { [("Authorization", "Bearer T"), ("X-OmacVM-Relay", "K"), ("X-OmacVM-App-VM", "Vk0=")] }
func relay(_ fb: FakeBridge, headers h: @escaping () -> [(String, String)]? = headers, connect: (() -> Int32?)? = nil) -> (Int32, AuthRelay) {
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: connect ?? { fb.connect() }, headers: h)
    r.pingTimeout = 0.6
    Thread.detachNewThread { try? r.run() }
    return (vm, r)
}

// A yes from the Bridge reaches the VM unchanged.
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb)
    send(vm, ["op": "ping", "id": nonce])   // a ping for nothing: ignored
    send(vm, requestLine())
    let (got, _) = readAll(vm, timeout: 5, untilNewline: true)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["id"] as? String == nonce && o["status"] as? Int == 200 && o["answer"] as? String == sig
           && Data(base64Encoded: o["body"] as? String ?? "") == answerBody, "relay: the Bridge's signed answer to the VM, byte for byte")
    let req = String(decoding: fb.requests.first ?? Data(), as: UTF8.self)
    expect(req.contains("X-OmacVM-Auth: 1 1760000000 \(nonce) \(sig)\r\n") && req.contains("X-OmacVM-Relay: K\r\n"), "relay: request carries the guest's signature and the relay key")
    r.stop(); close(vm)
}

// No pings: the client is gone (Ctrl+C), the Bridge connection is dropped.
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    let t0 = Date()
    send(vm, requestLine())
    expect(fb.wait({ fb.closedEarly.count == 1 }), "relay: no pings -> Bridge connection dropped")
    let dt = Date().timeIntervalSince(t0)
    expect(fb.closedEarly.first == true && dt < 2.5, "relay: dropped within the ping timeout (\(String(format: "%.2f", dt)) s)")
    let (got, _) = readAll(vm, timeout: 0.3, untilNewline: true)
    expect(got.isEmpty, "relay: nothing written for a client that is gone")
    r.stop(); close(vm)
}

// Pings keep it up; a cancel drops it at once.
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    send(vm, requestLine())
    for _ in 0..<6 { usleep(250_000); send(vm, ["op": "ping", "id": nonce]) }   // 1.5 s, past the ping timeout
    expect(fb.closedEarly.isEmpty, "relay: pings keep the request up")
    let t0 = Date()
    send(vm, ["op": "cancel", "id": other])   // someone else's id: ignored
    send(vm, ["op": "cancel", "id": nonce])
    expect(fb.wait({ fb.closedEarly.count == 1 }, 1) && Date().timeIntervalSince(t0) < 0.6, "relay: cancel drops it at once")
    r.stop(); close(vm)
}

// A new request while one is open: the old one goes (one opener at a time).
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, r) = relay(fb)
    send(vm, requestLine())
    _ = fb.wait({ fb.requests.count == 1 })
    fb.lock.lock(); fb.answer = resp; fb.lock.unlock()
    send(vm, requestLine(id: other))
    expect(fb.wait({ fb.closedEarly.count == 1 }), "relay: a new request drops the old one")
    let (got, _) = readAll(vm, timeout: 5, untilNewline: true)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["id"] as? String == other && o["status"] as? Int == 200, "relay: the new one is answered")
    r.stop(); close(vm)
}

// The Bridge not set up, or not there: status 0 at once.
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb, headers: { nil })
    send(vm, requestLine())
    let (got, _) = readAll(vm, timeout: 2, untilNewline: true)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["status"] as? Int == 0 && fb.connects == 0, "relay: no Bridge token or relay key -> status 0, no connection")
    r.stop(); close(vm)
}
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb, connect: { nil })
    send(vm, requestLine())
    let (got, _) = readAll(vm, timeout: 2, untilNewline: true)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["status"] as? Int == 0, "relay: Bridge socket not there -> status 0")
    r.stop(); close(vm)
}

// Junk from the VM never reaches the Bridge; the relay keeps reading.
do {
    let fb = FakeBridge()
    let (vm, r) = relay(fb)
    let junk = Data(repeating: 0x41, count: 10000) + Data("\nnot json\n".utf8)
    _ = junk.withUnsafeBytes { write(vm, $0.baseAddress, $0.count) }
    send(vm, requestLine(auth: "1 1760000000 \(other) \(sig)"))
    send(vm, requestLine())
    let (got, _) = readAll(vm, timeout: 5, untilNewline: true)
    let o = (try? JSONSerialization.jsonObject(with: got.dropLast())) as? [String: Any] ?? [:]
    expect(o["status"] as? Int == 200 && fb.connects == 1, "relay: junk and a bad line dropped, the good one relayed")
    r.stop(); close(vm)
}

// The VM side closes (QEMU quits): run() returns, an open request is dropped.
do {
    let fb = FakeBridge(); fb.answer = nil
    let (vm, app) = pair()
    let r = AuthRelay(guest: app, connectBridge: { fb.connect() }, headers: headers)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { try? r.run(); done.signal() }
    send(vm, requestLine())
    _ = fb.wait({ fb.requests.count == 1 })
    close(vm)
    expect(done.wait(timeout: .now() + 2) == .success, "relay: run() returns when the port's socket closes")
    expect(fb.wait({ fb.closedEarly.count == 1 }, 2), "relay: and the open request is dropped")
    r.stop()
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
