// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmacVM",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "OmacVM", dependencies: ["OmacVMUpdate"]),
        // The self-update's checks, apart from the UI so they can be tested
        // without Xcode: `swift run update-tests`.
        .target(name: "OmacVMUpdate"),
        .executableTarget(name: "update-tests", dependencies: ["OmacVMUpdate"]),
    ],
    swiftLanguageModes: [.v5]
)
