import CryptoKit
import Foundation

/// OmacVM's release keys (docs/release-keys.md). Two Ed25519 public keys
/// ship with every copy: the main one (src/lib/release-key.pub) and a spare
/// (src/lib/release-key-spare.pub). A document signed by either is valid,
/// so losing the main private key does not cut installed copies off.
///
/// A signed document may name a new spare ("next_spare_key"). It is kept
/// as the document itself plus its signature, never as a bare key: a key
/// file in ~/Library could be written by any process of the user, a signed
/// document only by whoever holds a release key. The trusted keys are the
/// shipped ones plus the keys named by kept documents that one of them (or
/// an earlier named key) signed. A later app that no longer ships a key
/// therefore also drops what that key named.
///
/// A document signed by a shipped key may revoke named keys
/// ("revoked_keys", kept the same way): for a named spare that leaked.
/// A revoked key and everything it signed are not trusted any more.
///
/// The Bridge (src/bridge/mac/control_policy.swift) and the command line
/// (src/release/keys.py) read and write the same folder the same way.
public struct ReleaseKeys: Sendable {
    /// Base64 of the raw 32-byte public keys that ship with this copy.
    public let shipped: [String]
    /// The kept documents: ~/Library/Application Support/omacvm/release-keys.
    public let store: URL?

    public static let kinds: Set<String> = ["app-feed", "control-manifest", "prebuilt-manifest"]
    /// Documents used from the folder, and files looked at there.
    public static let maxKept = 8
    static let maxScan = 256
    public static let maxRevoked = 8
    static let maxDocumentBytes = 256 * 1024

    public init(shipped: [String], store: URL?) {
        self.shipped = shipped
        self.store = store
    }

    /// A public key from base64 of its raw 32 bytes; nil for anything else.
    public static func key(_ b64: String) -> Curve25519.Signing.PublicKey? {
        guard let d = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)), d.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: d)
    }

    /// The signature file's text: base64 of 64 bytes.
    static func signatureBytes(_ sig: Data) -> Data? {
        let text = String(decoding: sig, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let s = Data(base64Encoded: text), s.count == 64 else { return nil }
        return s
    }

    static func signed(_ data: Data, _ sig: Data, by keys: [Curve25519.Signing.PublicKey]) -> Bool {
        guard let s = signatureBytes(sig) else { return false }
        return keys.contains { $0.isValidSignature(s, for: data) }
    }

    /// "revoked_keys": 1 to maxRevoked distinct keys; nil for anything else.
    public static func revokedKeys(_ v: Any?) -> [Curve25519.Signing.PublicKey]? {
        guard let a = v as? [Any], (1...maxRevoked).contains(a.count) else { return nil }
        let keys = a.compactMap { ($0 as? String).flatMap(key) }
        guard keys.count == a.count, Set(keys.map(\.rawRepresentation)).count == keys.count else { return nil }
        return keys
    }

    /// A document that may change the trusted keys: it names a spare, or
    /// revokes keys, or both. Not verified yet.
    struct Doc {
        let data: Data, sig: Data
        let named: Curve25519.Signing.PublicKey?
        let revokes: [Curve25519.Signing.PublicKey]

        init?(_ data: Data, _ sig: Data) {
            guard data.count <= ReleaseKeys.maxDocumentBytes, sig.count <= 1024, ReleaseKeys.signatureBytes(sig) != nil,
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let kind = o["kind"] as? String, ReleaseKeys.kinds.contains(kind) else { return nil }
            named = (o["next_spare_key"] as? String).flatMap(ReleaseKeys.key)
            revokes = ReleaseKeys.revokedKeys(o["revoked_keys"]) ?? []
            guard named != nil || !revokes.isEmpty else { return nil }
            self.data = data
            self.sig = sig
        }
    }

    /// The trusted keys, the revoked ones and the documents used (indexes).
    /// Revocations count only when a shipped key signed them, and never
    /// revoke a shipped key (a release drops one by not shipping it), so a
    /// leaked named spare cannot revoke the keys that would replace it. A
    /// revocation is used once per shipped key that signs it, so it still
    /// holds after a release stops shipping one of them. Then the named spares, each signed by a trusted key that is not
    /// revoked: what a revoked key signed (and the chain after it) is not
    /// trusted. At most maxKept documents are used; one that does not
    /// verify uses none, so junk in the folder cannot crowd out real ones.
    static func resolve(shipped: [Curve25519.Signing.PublicKey], docs: [Doc])
        -> (keys: [Curve25519.Signing.PublicKey], revoked: Set<Data>, used: [Int]) {
        var known = Set<Data>(), keys: [Curve25519.Signing.PublicKey] = []
        for k in shipped where known.insert(k.rawRepresentation).inserted { keys.append(k) }
        let base = keys
        var revoked = Set<Data>(), used: [Int] = [], by: [Data: Set<Data>] = [:]
        for (i, d) in docs.enumerated() where !d.revokes.isEmpty && used.count < maxKept {
            guard let signer = base.first(where: { signed(d.data, d.sig, by: [$0]) })?.rawRepresentation else { continue }
            let new = Set(d.revokes.map(\.rawRepresentation)).subtracting(known).subtracting(by[signer, default: []])
            if !new.isEmpty { by[signer, default: []].formUnion(new); revoked.formUnion(new); used.append(i) }
        }
        // Each document is checked once against each key, as the key comes in.
        var fresh = base
        var left = docs.indices.filter { docs[$0].named != nil }
        while !fresh.isEmpty && !left.isEmpty {
            var added: [Curve25519.Signing.PublicKey] = []
            for i in left where signed(docs[i].data, docs[i].sig, by: fresh) {
                left.removeAll { $0 == i }
                let k = docs[i].named!, raw = k.rawRepresentation
                guard !revoked.contains(raw), !known.contains(raw), used.contains(i) || used.count < maxKept else { continue }
                known.insert(raw)
                keys.append(k)
                added.append(k)
                if !used.contains(i) { used.append(i) }
            }
            fresh = added
        }
        return (keys, revoked, used)
    }

    /// The shipped keys plus those named by kept documents, as far as a
    /// trusted key signed them (a named key may sign the next one), minus
    /// the revoked ones.
    public func trusted() -> [Curve25519.Signing.PublicKey] {
        Self.resolve(shipped: shipped.compactMap(Self.key), docs: kept()).keys
    }

    /// Signed by a trusted key.
    public func verifies(_ data: Data, signature: Data) -> Bool {
        Self.signed(data, signature, by: trusted())
    }

    /// What keeping a document changed.
    public struct Remembered: Equatable, Sendable {
        /// Newly trusted keys (base64).
        public let named: [String]
        /// Newly revoked keys (base64).
        public let revoked: [String]
    }

    /// Keeps a verified document that names a key not trusted yet or
    /// revokes one not revoked yet (and fits under maxKept). nil: nothing
    /// kept.
    @discardableResult
    public func remember(_ data: Data, signature: Data) -> Remembered? {
        guard let store, let doc = Doc(data, signature) else { return nil }
        let base = shipped.compactMap(Self.key), docs = kept()
        let before = Self.resolve(shipped: base, docs: docs), after = Self.resolve(shipped: base, docs: docs + [doc])
        let old = Set(before.keys.map(\.rawRepresentation))
        let named = after.keys.map(\.rawRepresentation).filter { !old.contains($0) }
        let revoked = after.revoked.subtracting(before.revoked)
        guard after.used.contains(docs.count), !named.isEmpty || !revoked.isEmpty || !doc.revokes.isEmpty else { return nil }
        let name = SHA256.hash(data: data + signature).prefix(8).map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try signature.write(to: store.appendingPathComponent("\(name).json.sig"), options: .atomic)
            try data.write(to: store.appendingPathComponent("\(name).json"), options: .atomic)
        } catch { return nil }
        return Remembered(named: named.map { $0.base64EncodedString() }, revoked: revoked.map { $0.base64EncodedString() }.sorted())
    }

    /// The documents in the folder that could matter: at most maxScan files
    /// are looked at; unreadable ones and junk are skipped.
    func kept() -> [Doc] {
        guard let store, let names = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return [] }
        return names.filter { $0.range(of: "^[0-9a-f]{16}\\.json$", options: .regularExpression) != nil }.sorted()
            .prefix(Self.maxScan).compactMap { n in
                let f = store.appendingPathComponent(n), g = f.appendingPathExtension("sig")
                guard Self.size(f) <= Self.maxDocumentBytes, Self.size(g) <= 1024,
                      let d = try? Data(contentsOf: f), let s = try? Data(contentsOf: g) else { return nil }
                return Doc(d, s)
            }
    }

    private static func size(_ f: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? Int.max
    }
}
