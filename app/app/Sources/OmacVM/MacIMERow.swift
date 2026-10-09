import Foundation
import OmacVMFeatures
import SwiftUI

/// The Mac's input methods in the VM (feature mac-ime: experimental, off by
/// default; docs/adr/0043-mac-ime.md) in the VM window's form: one switch,
/// the same feature as in the control centre (Features…) and `omacvm
/// enable/disable mac-ime`. While the VM runs it runs this app's omacvm for
/// the VM (its Fcitx5 gets a small module); the port comes with the VM's next
/// start. While the VM is stopped it writes the choice into the VM's record
/// and a pending file (MacIME.pendingFile): the next start has the port (or
/// none), and the app sets up the VM's part at that start (MacIMEStart).
/// Nothing changes for a VM that leaves it off.
struct MacIMERow: View {
    @ObservedObject var state: AppState
    @State private var record: String?
    @State private var pending: String?
    @State private var busy = false
    @State private var note: String?

    static let info = "Experimental. Type in Omarchy with the Mac's input method for Chinese, Japanese, Korean, Vietnamese and other languages that use a candidate window; normal keyboard layouts (accents included) do not need it. With it: the Mac's candidate window opens at the text cursor in the VM, and the chosen text goes into the VM's text field. Keys, shortcuts and the VM's own input methods stay as they are; password fields always get plain keys. Switched while the VM is stopped, it is set up at the VM's next start; switched while it runs, it works from the VM's next start."

    var body: some View {
        let running = state.vmRunning()
        let row = MacIME.row(record: record, pending: pending, running: running, busy: busy, cli: TerminalCommand.available)
        SwitchRow("Mac input (Chinese, Japanese, Korean)",
                  isOn: Binding(get: { row.on }, set: { v in if v != row.on { flip(v, running: running) } }),
                  enabled: row.enabled) {
            if busy { ProgressView().controlSize(.small) }
            InfoButton(topic: "the Mac's input methods", text: Self.info)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in note = nil; refresh() }
        .onChange(of: running) { _, _ in note = nil; refresh() }
        .onReceive(NotificationCenter.default.publisher(for: MacIMEStart.done)) { _ in refresh() }
        if let n = note ?? row.note { RowNote(n, error: n.hasPrefix("Could not")) }
    }

    private func refresh() {
        let f = state.config.folder
        record = try? String(contentsOf: f.appendingPathComponent("features"), encoding: .utf8)
        pending = try? String(contentsOf: f.appendingPathComponent(MacIME.pendingFile), encoding: .utf8)
    }

    private func flip(_ value: Bool, running: Bool) {
        if running { run(value) } else { write(value) }
    }

    /// The VM is stopped: the record and the pending file, for its next start.
    private func write(_ value: Bool) {
        let f = state.config.folder
        let next = MacIME.switchStopped(record: record, pending: pending, on: value)
        let pendingURL = f.appendingPathComponent(MacIME.pendingFile)
        do {
            try next.record.write(to: f.appendingPathComponent("features"), atomically: true, encoding: .utf8)
            if let p = next.pending { try p.write(to: pendingURL, atomically: true, encoding: .utf8) }
            else if FileManager.default.fileExists(atPath: pendingURL.path) { try FileManager.default.removeItem(at: pendingURL) }
            note = nil
        } catch {
            note = "Could not switch: \(error.localizedDescription)"
        }
        refresh()
    }

    /// `omacvm enable|disable mac-ime` for this VM, off the main thread.
    private func run(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = Self.run([value ? "enable" : "disable", MacIME.feature, "--vm", c.name, "--vm-type", "app", "--yes"])
            // Switched now: nothing left for the next start.
            if err == nil { try? FileManager.default.removeItem(at: c.folder.appendingPathComponent(MacIME.pendingFile)) }
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
                else { note = value ? "On from the VM's next start: shut it down, then start it again." : "Off. The VM's next start has no port for it." }
            }
        }
    }

    /// nil when it worked, else the CLI's last line.
    nonisolated static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TerminalCommand.appCLI)
        p.arguments = args
        p.environment = TestIdentity.environment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let last = plain.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return last.isEmpty ? "omacvm \(args.first ?? "") exited \(p.terminationStatus)" : last
    }
}

/// At the VM's start: a choice made in the row while the VM was stopped
/// (#316; MacIME.prepareStart before the start). The record already says it (the port comes with this start or
/// not); once the guest agent answers, the app's omacvm sets up or removes
/// the VM's part (apply's switch of mac-ime alone). Done: the pending file
/// goes. Failed: it stays for the next start, and qemu.log says why.
enum MacIMEStart {
    static let done = Notification.Name("OmacVM.MacIMEStart.done")

    static func run(config c: VMConfig, on: Bool, agentPath: String, running: @escaping () -> Bool,
                    log: @escaping (String) -> Void) {
        Thread.detachNewThread {
            // The guest agent starts with Omarchy: up to ten minutes.
            let deadline = Date().addingTimeInterval(600)
            var up = false
            while running(), Date() < deadline {
                if GuestAgent.execute(socketPath: agentPath, "{\"execute\":\"guest-ping\"}")?.contains("\"return\"") == true { up = true; break }
                Thread.sleep(forTimeInterval: 5)
            }
            guard up, running() else { return }
            let what = "Mac input methods \(on ? "on" : "off") (switched while the VM was stopped)"
            log("OmacVM: \(what): setting up the VM's part")
            let err = MacIMERow.run(MacIME.applyArguments(vm: c.name, on: on))
            let url = c.folder.appendingPathComponent(MacIME.pendingFile)
            if let err {
                log("OmacVM: \(what): not set up, tried again at the next start: \(err)")
            } else {
                // Only when it was not switched again meanwhile.
                if MacIME.pending(try? String(contentsOf: url, encoding: .utf8)) == on { try? FileManager.default.removeItem(at: url) }
                log("OmacVM: \(what): set up in the VM")
            }
            DispatchQueue.main.async { NotificationCenter.default.post(name: done, object: nil) }
        }
    }
}
