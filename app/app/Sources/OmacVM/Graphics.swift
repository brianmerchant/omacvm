import Foundation

/// The VM's graphics: OpenGL only, OpenGL plus Vulkan (Venus), or Automatic.
/// Kept per VM in the VM folder's `graphics` file (opengl, vulkan or auto;
/// none means auto), set in the app's setup and VM window, with
/// `omacvm graphics` and in the control centre. Foundation only, so
/// src/tests/graphics-setting.sh can test it on its own; src/lib/graphics.sh
/// has the same rules for the Mac side of omacvm (that test keeps them equal).
enum GraphicsChoice: String, CaseIterable {
    case auto, opengl, vulkan

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .opengl: return "OpenGL"
        case .vulkan: return "Vulkan"
        }
    }
}

/// What one start of a VM gets.
struct GraphicsPlan: Equatable {
    var choice: GraphicsChoice
    /// The Venus device (Vulkan) at this start.
    var venus: Bool
    /// Its host memory window in GB (a power of two).
    var hostmemGB: Int
    /// Why, for qemu.log ("OmacVM: graphics: ...") and omacvm check.
    var why: String

    var record: String {
        "\(choice.rawValue) -> \(venus ? "vulkan" : "opengl") (\(why))" + (venus ? ", host memory window \(hostmemGB) GB" : "")
    }
}

enum Graphics {
    static let fileName = "graphics"
    /// Written by omacvm apply when the VM has a Venus driver that sizes GPU
    /// memory to the Mac's 16 KiB pages (Mesa 26.2.4 or newer, or OmacVM's
    /// Mesa of the vulkan feature). Automatic waits for it.
    static let readyFileName = "venus-ready"

    /// Automatic gives Vulkan from this macOS on, and only with KosmicKrisp in
    /// the app (Metal 4). Numbers: docs/benchmarks/README.md ("Graphics:
    /// Automatic"). On older macOS Venus runs on MoltenVK, which cannot carry
    /// OpenGL or WebGL (ES 2.0 only): Automatic stays on OpenGL there, and
    /// Vulkan is the user's choice.
    static let autoVulkanFromMacOS = 26
    static let autoVulkanOnMoltenVK = false

    static func read(folder: URL) -> GraphicsChoice {
        let url = folder.appendingPathComponent(fileName)
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return .auto }
        return GraphicsChoice(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .auto
    }

    static func write(_ c: GraphicsChoice, folder: URL) throws {
        try Data("\(c.rawValue)\n".utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }

    static func driverReady(folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(readyFileName).path)
    }

    /// What Automatic picks on this Mac, without the VM (the setup's caption).
    static func autoPicksVulkan(macOSMajor: Int, kosmicKrisp: Bool) -> Bool {
        (macOSMajor >= autoVulkanFromMacOS && kosmicKrisp) || autoVulkanOnMoltenVK
    }

    /// The Venus host memory window, from the VM's memory plan (one memory
    /// pool on Apple Silicon): what this Mac has beyond the VM's own memory and
    /// macOS's reserve (4 GB up to 16 GB, 6 GB up to 36 GB, 8 GB above), as a
    /// power of two between 1 and 32 GB. It is address space for mapping Vulkan
    /// memory into the VM; what Vulkan really allocates counts against the
    /// GPU memory budget (gpu-robust's budget patch).
    static func hostmemGB(macMemoryGB: Int, vmMemoryGB: Int) -> Int {
        let reserve = macMemoryGB <= 16 ? 4 : macMemoryGB <= 36 ? 6 : 8
        let free = min(max(macMemoryGB - vmMemoryGB - reserve, 1), 32)
        var p = 1
        while p * 2 <= free { p *= 2 }
        return p
    }

    /// The plan for one start. `forced`: the vulkan feature (the VM's
    /// `vulkan` file, OmacVM's Mesa for WebGPU and OpenCL) or the hidden
    /// `venus` switch, which keep Venus on whatever the choice.
    static func plan(choice: GraphicsChoice, macOSMajor: Int, kosmicKrisp: Bool, driverReady: Bool,
                     forced: Bool, macMemoryGB: Int, vmMemoryGB: Int) -> GraphicsPlan {
        let mem = hostmemGB(macMemoryGB: macMemoryGB, vmMemoryGB: vmMemoryGB)
        let driver = macOSMajor >= 26 && kosmicKrisp ? "KosmicKrisp" : "MoltenVK"
        func p(_ venus: Bool, _ why: String) -> GraphicsPlan {
            GraphicsPlan(choice: choice, venus: venus, hostmemGB: mem, why: why)
        }
        if forced { return p(true, "WebGPU and GPU compute (vulkan feature) need Vulkan, \(driver)") }
        switch choice {
        case .opengl: return p(false, "chosen")
        case .vulkan: return p(true, "chosen, \(driver)")
        case .auto:
            guard autoPicksVulkan(macOSMajor: macOSMajor, kosmicKrisp: kosmicKrisp) else {
                return p(false, kosmicKrisp || macOSMajor >= autoVulkanFromMacOS
                         ? "macOS \(macOSMajor) without KosmicKrisp in this app: MoltenVK, OpenGL stays"
                         : "macOS \(macOSMajor): MoltenVK, OpenGL stays")
            }
            guard driverReady else { return p(false, "the VM has no Venus driver for 16 KiB pages yet: omacvm apply") }
            return p(true, "macOS \(macOSMajor), \(driver)")
        }
    }
}
