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

    /// The next start in words, as omacvm graphics and the control centre
    /// say it: "Vulkan (driver not built yet: ...)" while a VM set to Vulkan
    /// waits for its driver.
    var summary: String {
        venus ? "OpenGL and Vulkan" : choice == .vulkan ? "Vulkan (\(why))" : "OpenGL"
    }

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

    /// Automatic gives Vulkan at all. 3.0.1: no, on every Mac. Vulkan windows
    /// show through the GPU (virgl-set-type-without-egl.patch), but what Vulkan
    /// costs the OpenGL desktop on KosmicKrisp is not measured yet, so Vulkan
    /// is the user's choice. true turns the macOS 26+ rule below on (src/lib/graphics.sh:
    /// GRAPHICS_AUTO_VULKAN, kept equal by src/tests/graphics-setting.sh).
    static let autoVulkan = false
    /// With autoVulkan: Vulkan from this macOS on, and only with KosmicKrisp
    /// in the app (Metal 4). On older macOS Venus runs on MoltenVK, which
    /// cannot carry OpenGL or WebGL (ES 2.0 only): OpenGL there.
    /// Numbers: docs/benchmarks/README.md ("Graphics: Automatic").
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
        autoVulkan && ((macOSMajor >= autoVulkanFromMacOS && kosmicKrisp) || autoVulkanOnMoltenVK)
    }

    /// Why a VM set to Vulkan still starts with OpenGL: without a Venus
    /// driver for 16 KiB pages every Vulkan app would fail with
    /// ERROR_OUT_OF_HOST_MEMORY. `omacvm apply` (or `omacvm graphics` while
    /// the VM runs) builds it and writes venus-ready. Same text in omacvm.
    static let waitingForDriver = "driver not built yet: runs on OpenGL until the next apply"

    /// Up to 2.9 a hidden switch (`defaults write org.omacvm.app venus -bool
    /// true`) put Vulkan in every VM. 3.0.0 moves it once into the Graphics
    /// setting: a VM without a choice of its own (no file, or Automatic)
    /// gets Vulkan; one set to OpenGL keeps it. Returns what it changed, for
    /// the log; the caller removes the switch.
    static func migrateVenusSwitch(folders: [URL]) -> [String] {
        var out: [String] = []
        for f in folders where read(folder: f) == .auto {
            do {
                try write(.vulkan, folder: f)
                out.append("'\(f.lastPathComponent)': Graphics Vulkan (the hidden venus switch was on)")
            } catch {
                out.append("'\(f.lastPathComponent)': could not set Graphics to Vulkan: \(error.localizedDescription)")
            }
        }
        return out
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
    /// `vulkan` file: OmacVM's Mesa for WebGPU and OpenCL, which apply only
    /// writes once that Mesa is in the VM), which keeps Venus on whatever the
    /// choice.
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
        case .vulkan:
            guard driverReady else { return p(false, waitingForDriver) }
            return p(true, "chosen, \(driver)")
        case .auto:
            guard autoVulkan else { return p(false, "Automatic is OpenGL on every Mac in this version; Vulkan is your choice") }
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
