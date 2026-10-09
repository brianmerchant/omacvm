import OmacVMWindow
import SwiftUI

extension VMConfig {
    /// This VM as it starts on this Mac: CPUs and memory this Mac does not
    /// allow (a VM copied from a bigger Mac) are the Best tier's, for this
    /// start only (vm.env stays). ResourceLimits.startSize.
    var forThisMac: VMConfig {
        guard let s = ResourceLimits.mac.startSize(cpus: cpus, memoryMB: memoryMB, best: Mac.tier(3)) else { return self }
        var c = self
        c.cpus = s.cpus
        c.memoryMB = s.memoryMB
        return c
    }

    /// The window's note when forThisMac differs from vm.env.
    var startSizeNote: String? {
        let s = forThisMac
        guard s != self else { return nil }
        return ResourceLimits.mac.startSizeText(cpus: cpus, memoryMB: memoryMB, start: (s.cpus, s.memoryMB))
    }
}

extension ResourceLimits {
    /// This Mac's, as `omacvm resources` has them.
    static var mac: ResourceLimits { ResourceLimits(macCores: Mac.cores, macMemoryGB: Mac.memoryGB) }
}

/// Resources › Custom… in the VM window: CPUs and memory one by one, within
/// the CLI's limits (OmacVMWindow/CustomResources.swift). Applies at the
/// next start.
struct CustomResourcesSheet: View {
    let limits = ResourceLimits.mac
    @State private var cpus: Int
    @State private var memoryGB: Int
    var onSave: (Int, Int) -> Void
    var onCancel: () -> Void

    init(cpus: Int, memoryMB: Int, onSave: @escaping (Int, Int) -> Void, onCancel: @escaping () -> Void) {
        let v = ResourceLimits.mac.clamp(cpus: cpus, memoryGB: memoryMB / 1024)
        _cpus = State(initialValue: v.cpus)
        _memoryGB = State(initialValue: v.memoryGB)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Resources").font(.title3.bold())
            Text("This Mac has \(limits.macCores) CPUs and \(limits.macMemoryGB) GB memory. Applies at the next start.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Stepper("CPUs: \(cpus)", value: $cpus, in: limits.cpus)
            Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: limits.memoryGB)
            if let w = limits.warning(memoryGB: memoryGB) {
                Text(w).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(cpus, memoryGB) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(limits.problem(cpus: cpus, memoryGB: memoryGB) != nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
