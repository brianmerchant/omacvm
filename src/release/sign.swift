// Release signing (docs/adr/0032): Ed25519 with CryptoKit, as the Bridge
// verifies it.
//   swift sign.swift keygen PRIVATE_KEY_FILE    writes a new key (base64, mode 600),
//                                               prints the public key for src/lib/release-key.pub
//   swift sign.swift sign PRIVATE_KEY_FILE FILE  prints FILE's signature (base64): FILE.sig
//   swift sign.swift verify PUBLIC_KEY FILE SIG_FILE
// PRIVATE_KEY_FILE "-" reads the key from stdin (from the Keychain, so it
// never lands in a file: app/scripts/appcast.sh).
import CryptoKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }
func read(_ p: String) -> Data {
  if p == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
  guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else { fail("cannot read \(p)") }
  return d
}
func b64(_ d: Data) -> Data {
  guard let v = Data(base64Encoded: String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("not base64") }
  return v
}
let a = CommandLine.arguments
switch (a.count, a.count > 1 ? a[1] : "") {
case (3, "keygen"):
  let k = Curve25519.Signing.PrivateKey()
  guard FileManager.default.createFile(atPath: a[2], contents: Data(k.rawRepresentation.base64EncodedString().utf8),
                                       attributes: [.posixPermissions: 0o600]) else { fail("cannot write \(a[2])") }
  print(k.publicKey.rawRepresentation.base64EncodedString())
case (4, "sign"):
  guard let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: b64(read(a[2]))) else { fail("not a private key") }
  guard let sig = try? k.signature(for: read(a[3])) else { fail("signing failed") }
  print(sig.base64EncodedString())
case (5, "verify"):
  guard let k = try? Curve25519.Signing.PublicKey(rawRepresentation: b64(Data(a[2].utf8))) else { fail("not a public key") }
  if k.isValidSignature(b64(read(a[4])), for: read(a[3])) { print("good signature") } else { print("BAD signature"); exit(1) }
default:
  fail("usage: swift sign.swift keygen KEY | sign KEY FILE | verify PUBKEY FILE SIG")
}
