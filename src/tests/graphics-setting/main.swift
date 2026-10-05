// The app's Graphics rules (Graphics.swift) for src/tests/graphics-setting.sh:
// one line per case, "choice macos kk ready forced macgb vmgb -> venus hostmem".
import Foundation

let args = CommandLine.arguments
if args.count > 1 && args[1] == "file" {
    // file DIR: what the app reads from a VM folder.
    print(Graphics.read(folder: URL(fileURLWithPath: args[2])).rawValue)
    exit(0)
}
for c in GraphicsChoice.allCases {
    for macos in [15, 26, 27] {
        for kk in [false, true] {
            for ready in [false, true] {
                for forced in [false, true] {
                    for (mac, vm) in [(8, 4), (16, 8), (24, 12), (36, 16), (48, 24), (64, 32), (128, 16), (128, 48)] {
                        let p = Graphics.plan(choice: c, macOSMajor: macos, kosmicKrisp: kk, driverReady: ready,
                                              forced: forced, macMemoryGB: mac, vmMemoryGB: vm)
                        print("\(c.rawValue) \(macos) \(kk ? 1 : 0) \(ready ? 1 : 0) \(forced ? 1 : 0) \(mac) \(vm) -> \(p.venus ? "vulkan" : "opengl") \(p.hostmemGB)")
                    }
                }
            }
        }
    }
}
