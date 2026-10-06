import Foundation

/// Runs scripts/create-vm.sh (or prebuilt-vm.sh: the VM from a prebuilt image)
/// and turns its output into progress for the UI. Both take the same vm.env
/// and password and print the same STEP and ==> lines.
@MainActor
final class Creator: ObservableObject {
    @Published var step = 0
    @Published var steps = 6
    @Published var title = ""
    @Published var detail = ""
    @Published var failed: String?
    @Published var warning: String?
    @Published var finished = false
    private var process: Process?
    private var buffer = ""
    private var run = 0
    private var reader: FileHandle?
    private var exitStatus: Int32?
    private var logURL: URL?

    /// What runs: a new VM (create-vm.sh, prebuilt-vm.sh) or an existing VM's
    /// OmacVM brought up to this app's (update-vm.sh).
    enum Job { case build, update }
    @Published private(set) var job = Job.build

    func start(config: VMConfig, password: String, prebuilt: Bool = false, graphics: GraphicsChoice = .auto) {
        reset(.build)
        do {
            try config.write()
            // Read by omacvm apply at the end of the build (the VM's Venus driver).
            try Graphics.write(graphics, folder: config.folder)
        } catch {
            failed = "Could not write the VM settings: \(error.localizedDescription)"
            return
        }
        launch(script: prebuilt ? "prebuilt-vm.sh" : "create-vm.sh", folder: config.folder,
               log: "create.log", input: password + "\n")
    }

    /// An existing VM (made by an older app): started without a window,
    /// OmacVM applied as at the end of a build, shut down. The VM's
    /// settings stay as they are.
    func update(config: VMConfig) {
        reset(.update)
        launch(script: "update-vm.sh", folder: config.folder, log: "update.log", input: nil)
    }

    /// The log of the last build or update.
    var log: URL? { logURL }

    private func reset(_ j: Job) {
        job = j
        failed = nil; warning = nil; finished = false; step = 0
        reader?.readabilityHandler = nil
        reader = nil; run += 1; buffer = ""; exitStatus = nil
        title = "Preparing"
    }

    private func launch(script: String, folder: URL, log logName: String, input text: String?) {
        let id = run
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Paths.scripts.appendingPathComponent(script).path, folder.path]
        p.environment = TestIdentity.environment()
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        let logURL = folder.appendingPathComponent(logName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        self.logURL = logURL
        let log = try? FileHandle(forWritingTo: logURL)
        // The main queue keeps the output in order, and the end of the output
        // after it: a failed build's last line (its ERROR:) is read before
        // the build counts as done.
        reader = output.fileHandleForReading
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else {
                h.readabilityHandler = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.outputEnded(id) } }
                return
            }
            log?.write(data)
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(id, status) } }
            // A process left behind that holds the pipe must not keep the build open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { MainActor.assumeIsolated { self?.outputEnded(id) } }
        }
        do {
            try p.run()
            if let text { input.fileHandleForWriting.write(Data(text.utf8)) }
            try? input.fileHandleForWriting.close()
            process = p
        } catch {
            reader?.readabilityHandler = nil
            reader = nil
            failed = "Could not start the \(job == .build ? "build" : "update"): \(error.localizedDescription)"
        }
    }

    func cancel() { process?.terminate() }

    /// The script still runs (an update's ERROR: comes before its VM is shut down).
    var running: Bool { process?.isRunning == true }

    private func exited(_ id: Int, _ status: Int32) {
        guard id == run else { return }
        exitStatus = status
        settle()
    }

    private func outputEnded(_ id: Int) {
        guard id == run, let r = reader else { return }
        r.readabilityHandler = nil
        reader = nil
        if !buffer.isEmpty { handle(buffer.trimmingCharacters(in: .whitespaces)); buffer = "" }
        settle()
    }

    /// Done once the build has exited and its output is read.
    private func settle() {
        guard reader == nil, let status = exitStatus else { return }
        exitStatus = nil
        if status == 0 {
            finished = true
        } else if failed == nil {
            failed = "The \(job == .build ? "build" : "update") stopped (exit \(status)). Log: \(logURL?.path ?? "")"
        }
    }

    private func consume(_ text: String) {
        buffer += text
        // curl's progress bar ends its updates with \r, the rest with \n.
        while let r = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<r]).trimmingCharacters(in: .whitespaces)
            buffer = String(buffer[buffer.index(after: r)...])
            handle(line)
        }
        if buffer.count > 4096 { buffer = String(buffer.suffix(512)) }
    }

    private func handle(_ line: String) {
        if line.hasPrefix("STEP ") {
            // STEP n/N title
            let parts = line.dropFirst(5).split(separator: " ", maxSplits: 1)
            if let nums = parts.first?.split(separator: "/"), nums.count == 2 {
                step = Int(nums[0]) ?? step
                steps = Int(nums[1]) ?? steps
            }
            title = parts.count > 1 ? String(parts[1]) : ""
            detail = ""
        } else if line.hasPrefix("==>") {
            detail = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{1B}[1;32m", with: "")
                .replacingOccurrences(of: "\u{1B}[0m", with: "")
        } else if line.hasPrefix("WARN:") {
            warning = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            detail = warning ?? ""
        } else if line.hasPrefix("ERROR:") {
            failed = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if let pct = line.split(separator: " ").last, pct.hasSuffix("%"),
                  line.contains("#") {
            detail = "Downloading \(pct)"
        }
    }
}

/// A prebuilt VM the app can download instead of building one
/// (scripts/prebuilt-vm.sh --lookup: the newest image for this version).
struct PrebuiltImage: Equatable {
    let release: String
    let bytes: Int64
    let omarchy: String

    var size: String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    /// Where the setup screen's lookup is.
    enum Lookup: Equatable {
        case checking
        case found(PrebuiltImage)
        case none
    }

    /// Off the main thread; nil when there is none, no connection, or no
    /// answer within 20 seconds (then the VM is built here).
    static func lookup() async -> PrebuiltImage? {
        let script = Paths.scripts.appendingPathComponent("prebuilt-vm.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return await Task.detached(priority: .utility) { () -> PrebuiltImage? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, "--lookup"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let deadline = Date().addingTimeInterval(20)
            while p.isRunning {
                if Date() > deadline { p.terminate(); return nil }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            // TAG BYTES OMARCHY_VERSION IMAGE_VERSION
            let f = String(decoding: data.prefix(1024), as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard f.count >= 3, let bytes = Int64(f[1]), bytes > 0,
                  f[2].count <= 80, f[2].allSatisfy({ $0.isASCII && !$0.isWhitespace && $0.asciiValue! >= 0x21 })
            else { return nil }
            return PrebuiltImage(release: String(f[0]), bytes: bytes, omarchy: String(f[2]))
        }.value
    }
}
