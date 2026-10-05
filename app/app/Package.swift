// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmacVM",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "OmacVM", dependencies: ["OmacVMNet"]),
        // When a running VM changes network (fast network <-> user network),
        // apart from QMP so it can be tested without a VM: `swift run net-tests`.
        .target(name: "OmacVMNet"),
        .executableTarget(name: "net-tests", dependencies: ["OmacVMNet"]),
    ],
    swiftLanguageModes: [.v5]
)
