// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmacVM",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "OmacVM", dependencies: ["OmacVMUpdate", "OmacVMNet"]),
        // The self-update's checks, apart from the UI so they can be tested
        // without Xcode: `swift run update-tests`.
        .target(name: "OmacVMUpdate"),
        .executableTarget(name: "update-tests", dependencies: ["OmacVMUpdate"]),
        // When a running VM changes network (fast network <-> user network),
        // apart from QMP so it can be tested without a VM: `swift run net-tests`.
        .target(name: "OmacVMNet"),
        .executableTarget(name: "net-tests", dependencies: ["OmacVMNet"]),
    ],
    swiftLanguageModes: [.v5]
)
