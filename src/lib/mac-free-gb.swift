// Free space in GB on the drive of a folder (default: the home folder), as
// Finder counts it: macOS frees caches and purgeable files when needed, which
// df leaves out. omacvm build's space checks (src/lib/tools.sh mac_tool).
import Foundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory()
let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
print((v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_000_000_000)
