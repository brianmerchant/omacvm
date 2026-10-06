// The Mac folder's QEMU arguments (OmacVMFolder), without a VM or Xcode:
//   cd app/app && swift run folder-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMFolder

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias P = MacFolderPlan
let there: (String) -> Bool = { _ in true }
let gone: (String) -> Bool = { _ in false }

// Off: no file, an empty file.
expect(P.plan(fileText: nil, isDirectory: there) == P.Plan(arguments: [], record: "off"), "no file: off")
expect(P.plan(fileText: "\n", isDirectory: there).arguments.isEmpty, "empty file: off")

// On: one fsdev and one device, the folder as written.
var p = P.plan(fileText: "/Users/me/Projects\n", isDirectory: there)
expect(p.arguments.count == 4 && p.arguments[0] == "-fsdev" && p.arguments[2] == "-device", "folder: -fsdev and -device")
expect(p.arguments[1].hasPrefix("local,id=macfs,path=/Users/me/Projects,security_model=none,"), "folder: local backend, security_model=none")
expect(p.arguments[1].contains("guest_owner_uid=1000,guest_owner_gid=1000"), "folder: shown as the desktop user's")
expect(p.arguments[3] == "virtio-9p-pci,fsdev=macfs,mount_tag=omacvm-mac", "folder: tag omacvm-mac")
expect(p.record == "/Users/me/Projects at ~/Mac", "folder: record")

// A comma cannot add QEMU options.
p = P.plan(fileText: "/Users/me/a,readonly=off,b", isDirectory: there)
expect(p.arguments[1].contains("path=/Users/me/a,,readonly=off,,b,security_model=none"), "comma written twice")

// Only the first line counts.
p = P.plan(fileText: "/Users/me/x\n/etc\n", isDirectory: there)
expect(p.arguments[1].contains("path=/Users/me/x,"), "first line only")

// Not usable: relative, the whole disk, "..", NUL.
for bad in ["Users/me", "/", "/Users/me/../..", "/Users/me/a\0b"] {
    let b = P.plan(fileText: bad, isDirectory: there)
    expect(b.arguments.isEmpty && b.record.hasPrefix("off this start: the setting"), "refused: \(bad.debugDescription)")
}

// Not there now (a drive not connected): the VM starts without it.
p = P.plan(fileText: "/Volumes/USB/work", isDirectory: gone)
expect(p.arguments.isEmpty && p.record == "off this start: /Volumes/USB/work is not there (a drive not connected?)", "missing folder: left out")

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
