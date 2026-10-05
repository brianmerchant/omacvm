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
/// The Bridge (src/bridge/mac/control_policy.swift) and the command line
/// (src/release/keys.py) read and write the same folder the same way.
public struct ReleaseKeys: Sendable {
    /// Base64 of the raw 32-byte public keys that ship with this copy.
    public let shipped: [String]
    /// The kept documents: ~/Library/Application Support/omacvm/release-keys.
    public let store: URL?

    public static let kinds: Set<String> = ["app-feed", "control-manifest", "prebuilt-manifest"]
    public static let maxKept = 8
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

    /// The new spare a document names, if it is a well-formed key.
    public static func namedKey(_ data: Data) -> String? {
        guard data.count <= maxDocumentBytes,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = o["kind"] as? String, kinds.contains(kind),
              let k = o["next_spare_key"] as? String, key(k) != nil else { return nil }
        return k.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The shipped keys plus those named by kept documents, as far as a
    /// trusted key signed them (a named key may sign the next one).
    public func trusted() -> [Curve25519.Signing.PublicKey] {
        var keys = shipped.compactMap(Self.key)
        var known = Set(keys.map(\.rawRepresentation))
        var left = kept()
        var grew = true
        while grew && !left.isEmpty {
            grew = false
            for (i, doc) in left.enumerated().reversed() where Self.signed(doc.data, doc.sig, by: keys) {
                left.remove(at: i)
                if let k = Self.namedKey(doc.data).flatMap(Self.key), known.insert(k.rawRepresentation).inserted {
                    keys.append(k)
                    grew = true
                }
            }
        }
        return keys
    }

    /// Signed by a trusted key.
    public func verifies(_ data: Data, signature: Data) -> Bool {
        Self.signed(data, signature, by: trusted())
    }

    /// Keeps a verified document that names a key not trusted yet. Returns
    /// the new key, or nil (nothing named, already trusted, store full).
    @discardableResult
    public func remember(_ data: Data, signature: Data) -> String? {
        guard let store, let named = Self.namedKey(data), let k = Self.key(named) else { return nil }
        let keys = trusted()
        guard Self.signed(data, signature, by: keys), !keys.contains(where: { $0.rawRepresentation == k.rawRepresentation }),
              kept().count < Self.maxKept else { return nil }
        let name = SHA256.hash(data: k.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try signature.write(to: store.appendingPathComponent("\(name).json.sig"), options: .atomic)
            try data.write(to: store.appendingPathComponent("\(name).json"), options: .atomic)
        } catch { return nil }
        return named
    }

    /// The kept documents with their signatures (unreadable ones skipped).
    func kept() -> [(data: Data, sig: Data)] {
        guard let store, let names = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { return [] }
        return names.filter { $0.range(of: "^[0-9a-f]{16}\\.json$", options: .regularExpression) != nil }.sorted()
            .prefix(Self.maxKept).compactMap { n in
                let f = store.appendingPathComponent(n)
                guard let d = try? Data(contentsOf: f), d.count <= Self.maxDocumentBytes,
                      let s = try? Data(contentsOf: f.appendingPathExtension("sig")), s.count <= 1024 else { return nil }
                return (d, s)
            }
    }
}
