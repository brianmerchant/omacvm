import CryptoKit
import Foundation

/// One release in the update feed: OmacVM-appcast.json in each GitHub
/// release, with OmacVM-appcast.json.sig next to it (Ed25519 over the exact
/// bytes, base64; docs/adr/0033). Nothing in it is used before the signature
/// checks out.
///
///     {"schema": 1, "kind": "app-feed", "version": "2.9.1",
///      "url": "https://github.com/gillesgoetsch/omacvm/releases/download/v2.9.1/OmacVM-2.9.1.zip",
///      "length": 123456789, "sha256": "<64 hex>", "minimum_macos": "15.0",
///      "notes_url": "https://github.com/gillesgoetsch/omacvm/releases/tag/v2.9.1",
///      "date": "2026-10-20T12:00:00Z", "devid_teams": ["722686Y34B"]}
///
/// "kind" is required: the same release keys sign the control centre's
/// manifest ("kind": "control-manifest"), and neither may pass for the other.
/// "devid_teams" (required, 1 to 4) are the Apple Developer ID teams the new
/// app may be signed by: a change of team is announced by a feed signed
/// with our own key that names both. "next_spare_key" (optional) names a
/// new spare release key (ReleaseKeys).
public struct Appcast: Equatable, Sendable {
    public var version: Version
    public var url: URL
    public var length: Int64
    public var sha256: String
    public var minimumMacOS: Version?
    public var notesURL: URL?
    public var teams: [String]
    public var nextSpareKey: String?

    public static let kind = "app-feed"
    public static let maxFeedBytes = 64 * 1024
    public static let maxSignatureBytes = 1024
    /// More than any OmacVM.app zip will be (about 60 MB now).
    public static let maxArchiveBytes: Int64 = 2 << 30

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case tooLarge, badSignature, noKey, malformed(String)
        public var description: String {
            switch self {
            case .tooLarge: "the update feed is too large"
            case .badSignature: "the update feed's signature does not match OmacVM's release keys"
            case .noKey: "no release key"
            case .malformed(let what): "the update feed is malformed (\(what))"
            }
        }
    }

    /// Checks the signature first (any trusted release key), then reads the fields.
    public static func verified(feed: Data, signature: Data, keys: ReleaseKeys) -> Result<Appcast, Problem> {
        guard feed.count <= maxFeedBytes, signature.count <= maxSignatureBytes else { return .failure(.tooLarge) }
        let trusted = keys.trusted()
        guard !trusted.isEmpty else { return .failure(.noKey) }
        guard ReleaseKeys.signed(feed, signature, by: trusted) else { return .failure(.badSignature) }
        return parse(feed)
    }

    /// The fields, strictly: wrong types, a bad version or digest, or a
    /// download that is not https (or plain http to this Mac, for tests) are refused.
    static func parse(_ data: Data) -> Result<Appcast, Problem> {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.malformed("not a JSON object"))
        }
        guard let schema = integer(o["schema"]), schema == 1 else { return .failure(.malformed("schema")) }
        guard o["kind"] as? String == kind else { return .failure(.malformed("kind")) }
        guard let vs = o["version"] as? String, let version = Version(vs) else { return .failure(.malformed("version")) }
        guard let us = o["url"] as? String, let url = URL(string: us), isAllowedDownload(url) else {
            return .failure(.malformed("url"))
        }
        guard let length = integer(o["length"]), length > 0, length <= maxArchiveBytes else {
            return .failure(.malformed("length"))
        }
        guard let sha = o["sha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            return .failure(.malformed("sha256"))
        }
        var minimum: Version?
        if let m = o["minimum_macos"] {
            guard let s = m as? String, let v = Version(s) else { return .failure(.malformed("minimum_macos")) }
            minimum = v
        }
        var notes: URL?
        if let n = o["notes_url"] {
            guard let s = n as? String, let u = URL(string: s), u.scheme == "https" else { return .failure(.malformed("notes_url")) }
            notes = u
        }
        guard let teams = CodeCheck.teams(o["devid_teams"]) else { return .failure(.malformed("devid_teams")) }
        var spare: String?
        if let k = o["next_spare_key"] {
            guard let s = k as? String, ReleaseKeys.key(s) != nil else { return .failure(.malformed("next_spare_key")) }
            spare = s
        }
        return .success(Appcast(version: version, url: url, length: length, sha256: sha,
                                minimumMacOS: minimum, notesURL: notes, teams: teams, nextSpareKey: spare))
    }

    /// https anywhere; http only to 127.0.0.1 or localhost (a test feed).
    public static func isAllowedDownload(_ url: URL) -> Bool {
        switch url.scheme {
        case "https": return url.host?.isEmpty == false
        case "http": return url.host == "127.0.0.1" || url.host == "localhost"
        default: return false
        }
    }

    /// A JSON integer, not a bool or a fraction (NSNumber holds all three).
    static func integer(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let i = n.int64Value
        return NSNumber(value: i) == n ? i : nil
    }
}

/// A release version: 1 to 4 numbers with dots (2.7.0, 2.10.1). OmacVM's
/// versions have no suffixes; a build whose version has one is not offered
/// updates.
public struct Version: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]
    public let description: String

    public init?(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[0-9]{1,6}(\\.[0-9]{1,6}){0,3}$", options: .regularExpression) != nil else { return nil }
        parts = t.split(separator: ".").map { Int($0)! }
        description = t
    }

    public init(_ os: OperatingSystemVersion) {
        self.init("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!
    }

    /// 2.7 and 2.7.0 are the same.
    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}
