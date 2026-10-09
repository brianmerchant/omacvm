import CryptoKit
import Darwin
import Foundation

/// OmacVM.app's VMs reach the Mac at 127.0.0.1, where any Mac program can
/// connect, or listen in Omanotch's place while it is not running. So both
/// sides prove they know OmacVM's Bridge token, the Mac first, and the token
/// itself never goes over the wire (text messages from the guest, lines back):
///   challenge <guest nonce>      from the guest, 32 hex digits
///   proof <mac nonce> <proof>    the Mac: HMAC-SHA256(token,
///                                "omanotch mac <addr> <guest nonce> <mac nonce>"), hex;
///                                <addr>: the Mac address it accepted on
///   proof <proof>                the guest, the same with "vm"
/// The guest wants <addr> to be the address it connected to (127.0.0.1 for
/// QEMU's 10.0.2.2, 192.168.77.1 on the app's fast network), so a proof that a
/// listener fetched from Omanotch on another address fails.
/// A test Omanotch's port and Bridge folder (OmacVM's test identity: 47911,
/// omacvm-test-bridge) come only from its launch arguments
/// (`open -n Omanotch.app --args -port 47911 -bridgeDir omacvm-test-bridge`),
/// never from the saved settings: on 2026-10-09 a test had saved both into
/// ch.gillesgoetsch.omanotch on a MacBook Air, and the person's own Omanotch
/// then listened on the test port with the test Bridge's token, so their
/// VM's notch stayed empty. Saved values of these keys are removed at start.
enum TestEndpoint {
    static let keys = ["port", "bridgeDir"]

    static func port(arguments: [String: Any]) -> UInt16 {
        let v = (arguments["port"] as? String).flatMap { UInt16($0) } ?? (arguments["port"] as? NSNumber)?.uint16Value
        return v.flatMap { $0 == 0 ? nil : $0 } ?? 47811
    }

    static func bridgeDir(arguments: [String: Any]) -> String {
        (arguments["bridgeDir"] as? String).flatMap { $0.isEmpty || $0.contains("/") || $0 == ".." ? nil : $0 } ?? "omacvm-bridge"
    }

    /// The keys a test left in the saved settings.
    static func stale(saved: [String: Any]) -> [String] {
        keys.filter { saved[$0] != nil }
    }

    /// The launch arguments (UserDefaults' argument domain).
    static var arguments: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }
}

enum GuestAuth {
    /// The Bridge's token, or nil when there is none (or it is too short).
    /// A test Omanotch takes the test Bridge's (TestEndpoint).
    static func token() -> [UInt8]? {
        let dir = TestEndpoint.bridgeDir(arguments: TestEndpoint.arguments)
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dir)/token").path
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let tok = Array(s.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        return tok.count >= 32 ? tok : nil
    }

    static func proof(token: [UInt8], who: String, addr: String, guestNonce: String, macNonce: String) -> String {
        let msg = Data("omanotch \(who) \(addr) \(guestNonce) \(macNonce)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: token))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// 16 random bytes in hex.
    static func nonce() -> String {
        var r = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&r, r.count)
        return r.map { String(format: "%02x", $0) }.joined()
    }

    static func isHex(_ s: Substring, count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    /// Constant time.
    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0 ..< a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    /// notchcast from before the proof says the token itself ("auth <token>").
    static func legacyTokenMatches(_ given: String) -> Bool {
        guard let want = token() else { return false }
        return same(want, Array(given.trimmingCharacters(in: .whitespaces).utf8))
    }
}
