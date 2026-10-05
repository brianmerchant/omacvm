// feed-check FEED ZIP VERSION KEYDIR [CURRENT...]
//
// A release's update feed and zip, checked with the app's own code
// (OmacVMUpdate) the way an installed OmacVM.app checks them before it
// stages an update: signature by a shipped release key (KEYDIR holds
// release-key.pub and release-key-spare.pub), the fields, the zip's size and
// SHA-256, one app with our bundle id and the feed's version, a Developer ID
// of a team the feed names on the app and on its QEMU. Also: the app carries
// the same public keys, and what an app of each CURRENT version is offered.
// Exit 0 when everything holds.
import Foundation
import OmacVMUpdate

var failed = false
func ok(_ s: String) { print("ok   \(s)") }
func bad(_ s: String) { print("FAIL \(s)"); failed = true }

let a = CommandLine.arguments
guard a.count >= 5 else {
    FileHandle.standardError.write(Data("usage: feed-check FEED ZIP VERSION KEYDIR [CURRENT...]\n".utf8))
    exit(2)
}
let feedURL = URL(fileURLWithPath: a[1]), zip = URL(fileURLWithPath: a[2]), want = a[3]
let keyDir = URL(fileURLWithPath: a[4])
let names = ["release-key.pub", "release-key-spare.pub"]
func readKeys(_ dir: URL) -> [String] {
    names.compactMap { (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) }
}
let shipped = readKeys(keyDir)
guard shipped.count == 2, shipped.allSatisfy({ ReleaseKeys.key($0) != nil }) else { bad("no two public keys in \(keyDir.path)"); exit(1) }

guard let raw = try? Data(contentsOf: feedURL),
      let sig = try? Data(contentsOf: feedURL.appendingPathExtension("sig")) else { bad("no \(feedURL.path)(.sig)"); exit(1) }
let feed: Appcast
switch Appcast.verified(feed: raw, signature: sig, keys: ReleaseKeys(shipped: shipped, store: nil)) {
case .success(let f): feed = f; ok("signature (shipped release key) and fields")
case .failure(let p): bad("\(p)"); exit(1)
}
feed.version == Version(want)! ? ok("version \(feed.version)") : bad("feed says \(feed.version), not \(want)")
let url = "https://github.com/gillesgoetsch/omacvm/releases/download/v\(want)/OmacVM-\(want).zip"
feed.url.absoluteString == url ? ok("url \(url)") : bad("url \(feed.url)")
Files.size(zip) == feed.length ? ok("length \(feed.length)") : bad("zip is \(Files.size(zip) ?? -1) bytes, feed \(feed.length)")
((try? Files.sha256(zip)) == feed.sha256) ? ok("sha256 \(feed.sha256)") : bad("zip's sha256 is not the feed's")
ok("devid_teams \(feed.teams.joined(separator: " "))")

// The zip's app, as Updater.verifyApp checks the staged copy.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("feed-check-\(getpid())")
defer { try? FileManager.default.removeItem(at: tmp) }
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
p.arguments = ["-x", "-k", zip.path, tmp.path]
try? p.run(); p.waitUntilExit()
if p.terminationStatus == 0, let app = Files.singleApp(in: tmp), let info = BundleInfo.read(app) {
    info.identifier == "org.omacvm.app" ? ok("bundle id org.omacvm.app") : bad("bundle id \(info.identifier)")
    Version(info.version) == feed.version ? ok("app version \(info.version)") : bad("app says \(info.version)")
    let req = CodeCheck.developerID(teams: feed.teams)
    if let why = CodeCheck.problem(app, requirement: req) { bad(why) } else { ok("app: Developer ID of the feed's team, deep strict") }
    let qemu = app.appendingPathComponent("Contents/Resources/runtime/bin/OmacVM")
    if let why = CodeCheck.problem(qemu, requirement: req) { bad(why) } else { ok("QEMU: Developer ID of the feed's team") }
    // The keys this app will trust for the next update.
    let lib = FileManager.default.enumerator(at: app.appendingPathComponent("Contents/Resources"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.first { $0.lastPathComponent == "release-key.pub" }?.deletingLastPathComponent()
    if let lib, readKeys(lib) == shipped { ok("app ships the same two release keys") } else { bad("the app does not ship src/lib's release keys") }
} else {
    bad("the zip does not hold one app")
}

let os = Version(ProcessInfo.processInfo.operatingSystemVersion)
for c in a.dropFirst(5) {
    guard let v = Version(c) else { bad("not a version: \(c)"); continue }
    print("     an app at \(v) on macOS \(os): \(UpdatePolicy.offer(feed, current: v, skipped: nil, os: os))")
}
print(failed ? "feed-check: FAILED" : "feed-check: all ok")
exit(failed ? 1 : 0)
