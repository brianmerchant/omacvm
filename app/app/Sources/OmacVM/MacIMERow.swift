import Foundation
import OmacVMFeatures
import SwiftUI

/// The Mac's input methods in the VM (feature mac-ime: experimental, off by
/// default; docs/adr/0043-mac-ime.md) in the VM window's form: one switch,
/// the same feature as in the control centre (Features…) and `omacvm
/// enable/disable mac-ime`. It runs this app's omacvm for the VM, so the VM
/// must run (its Fcitx5 gets a small module); the port comes with the VM's
/// next start. Nothing changes for a VM that leaves it off.
struct MacIMERow: View {
    @ObservedObject var state: AppState
    @State private var on = false
    @State private var busy = false
    @State private var note: String?

    static let info = "Experimental. Type in Omarchy with the Mac's input method for Chinese, Japanese, Korean, Vietnamese and other languages that use a candidate window; normal keyboard layouts (accents included) do not need it. With it: the Mac's candidate window opens at the text cursor in the VM, and the chosen text goes into the VM's text field. Keys, shortcuts and the VM's own input methods stay as they are; password fields always get plain keys. Switch it while the VM runs: it sets up a small part in the VM and works from the VM's next start."

    var body: some View {
        let running = state.vmRunning()
        SwitchRow("Mac input (Chinese, Japanese, Korean)",
                  isOn: Binding(get: { on }, set: { v in if v != on { flip(v) } }),
                  enabled: !busy && running && TerminalCommand.available) {
            if busy { ProgressView().controlSize(.small) }
            InfoButton(topic: "the Mac's input methods", text: Self.info)
        }
        .onAppear(perform: refresh)
        .onChange(of: state.config) { _, _ in note = nil; refresh() }
        if let n = note { RowNote(n, error: n.hasPrefix("Could not")) }
        else if !running && !busy && on { RowNote("On. To switch it off, start the VM first.") }
    }

    private func refresh() {
        let text = try? String(contentsOf: state.config.folder.appendingPathComponent("features"), encoding: .utf8)
        on = MacIME.isOn(features: text)
    }

    /// `omacvm enable|disable mac-ime` for this VM, off the main thread.
    private func flip(_ value: Bool) {
        let c = state.config
        busy = true
        note = nil
        Task.detached {
            let err = Self.run(value ? "enable" : "disable", vm: c.name)
            await MainActor.run {
                busy = false
                refresh()
                if let err { note = "Could not switch: \(err)" }
                else { note = value ? "On from the VM's next start: shut it down, then start it again." : "Off. The VM's next start has no port for it." }
            }
        }
    }

    /// nil when it worked, else the CLI's last line.
    nonisolated private static func run(_ verb: String, vm: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: TerminalCommand.appCLI)
        p.arguments = [verb, MacIME.feature, "--vm", vm, "--vm-type", "app", "--yes"]
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
        return last.isEmpty ? "omacvm \(verb) exited \(p.terminationStatus)" : last
    }
}
