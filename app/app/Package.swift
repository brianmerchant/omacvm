// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmacVM",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "OmacVM", dependencies: ["OmacVMUpdate", "OmacVMNet", "OmacVMUSB"]),
        // The self-update's checks, apart from the UI so they can be tested
        // without Xcode: `swift run update-tests`.
        .target(name: "OmacVMUpdate"),
        .executableTarget(name: "update-tests", dependencies: ["OmacVMUpdate"]),
        // A release's feed and zip, checked as an installed app checks them
        // (src/release/release.sh verify).
        .executableTarget(name: "feed-check", dependencies: ["OmacVMUpdate"]),
        // When a running VM changes network (fast network <-> user network),
        // apart from QMP so it can be tested without a VM: `swift run net-tests`.
        .target(name: "OmacVMNet"),
        .executableTarget(name: "net-tests", dependencies: ["OmacVMNet"]),
        // The VM's USB devices: which ones the Mac lets a VM have, the VM's
        // choice and QEMU's arguments, without a VM: `swift run usb-tests`.
        .target(name: "OmacVMUSB"),
        .executableTarget(name: "usb-tests", dependencies: ["OmacVMUSB"]),
    ],
    swiftLanguageModes: [.v5]
)
