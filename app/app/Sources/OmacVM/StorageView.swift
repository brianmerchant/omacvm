import AppKit
import SwiftUI

/// The VMs folder, each VM's size and place, moves between folders and the
/// downloads. Shared by the setup, the settings and the start-up offers.
@MainActor
final class StorageModel: ObservableObject {
    struct Entry: Identifiable {
        var id: String { folder.path }
        var name: String
        var folder: URL
        var size: Int64?
        /// In the hidden folder of 2.9 and older.
        var legacy: Bool
    }

    struct Moving {
        var name: String
        var phase: String
        var done: Int64
        var total: Int64
    }

    @Published var root = Paths.vmsRoot
    @Published var free: Int64?
    @Published var vms: [Entry] = []
    @Published var downloads: Int64?
    /// One line per VMs folder on a drive that is not connected.
    @Published var disconnected: [String] = []
    @Published var moving: Moving?
    @Published var note: String?
    @Published var noteIsError = false

    /// A VM runs or this app builds one: the start-up offers wait then.
    var appBusy: () -> Bool = { false }
    /// This app builds a VM (its downloads are in use).
    var building: () -> Bool = { false }
    /// A VM moved: the app reloads the one it shows.
    var onMoved: () -> Void = {}
    private var mover: FolderMover?
    private var refreshRun = 0

    func refresh() {
        root = Paths.vmsRoot
        disconnected = Paths.vmsRoots.compactMap { r in
            Storage.missingDrive(for: r).map { "\($0) is not connected: its VMs (\(r.path)) are back once it is." }
        }
        let legacy = Paths.vmsRoot.standardizedFileURL.path == Paths.legacyVMsRoot.path ? "" : Paths.legacyVMsRoot.path
        vms = VMConfig.all().map {
            Entry(name: $0.name, folder: $0.folder, size: nil,
                  legacy: $0.folder.deletingLastPathComponent().path == legacy)
        }
        refreshRun += 1
        let run = refreshRun, folders = vms.map(\.folder), root = root
        DispatchQueue.global(qos: .utility).async {
            let free = Storage.freeBytes(at: root)
            let sizes = folders.map { Storage.allocatedSize(of: $0) }
            let downloads = Storage.allocatedSize(of: Paths.downloads)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard run == self.refreshRun else { return }
                    self.free = Storage.missingDrive(for: root) == nil ? free : nil
                    for (i, s) in sizes.enumerated() where i < self.vms.count { self.vms[i].size = s }
                    self.downloads = downloads
                }
            }
        }
    }

    private func say(_ text: String, error: Bool = false) {
        note = text
        noteIsError = error
    }

    nonisolated static func short(_ url: URL) -> String { Storage.short(url) }

    // MARK: The VMs folder

    /// Asks for a new VMs folder. With VMs elsewhere: move them, keep them
    /// where they are (new VMs only), or cancel.
    func changeRoot() {
        guard moving == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Storage.existingAncestor(root)
        panel.prompt = "Use This Folder"
        panel.message = "Where VMs go, one folder per VM. An external drive works too (APFS or Mac OS Extended)."
        guard panel.runModal() == .OK, let url = panel.url?.standardizedFileURL else { return }
        if let p = VolumeCheck.problem(with: url) { say(p, error: true); return }
        guard url.path != root.standardizedFileURL.path else { return }
        if Paths.vmsRoots.contains(where: { url.path.hasPrefix($0.path + "/") }) {
            say("That folder is inside a VMs folder; pick one outside it.", error: true)
            return
        }
        let elsewhere = VMConfig.all().filter { $0.folder.deletingLastPathComponent().path != url.path }
        if elsewhere.isEmpty {
            setRoot(url)
            say("New VMs go to \(Self.short(url)).")
            return
        }
        let alert = NSAlert()
        let n = elsewhere.count == 1 ? "\(elsewhere[0].name)" : "your \(elsewhere.count) VMs"
        alert.messageText = "Move \(n) to \(Self.short(url))?"
        alert.informativeText = Storage.sameVolume(elsewhere[0].folder, url)
            ? "Same drive: it takes a moment. Or keep the VMs where they are; only new VMs go to the new folder."
            : "To another drive the VMs are copied, checked and then deleted here; that takes a while. Or keep them where they are; only new VMs go to the new folder."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "New VMs Only")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: move(elsewhere, to: url, setRoot: true)
        case .alertSecondButtonReturn:
            setRoot(url)
            say("New VMs go to \(Self.short(url)); the others stay where they are.")
        default: break
        }
    }

    /// New VMs go to NEW; folders that still hold VMs (or whose drive is not
    /// connected) are still searched.
    private func setRoot(_ new: URL) {
        let old = Paths.vmsRoots
        Paths.vmsRoot = new
        let legacy = Paths.legacyVMsRoot.path
        Paths.otherVMsRoots = old.filter { r in
            r.path != new.standardizedFileURL.path && r.path != legacy
                && (Storage.missingDrive(for: r) != nil || VMsFolder.hasVMs(r, fm: .default))
        }
        refresh()
    }

    /// The VMs in 2.9's hidden folder (none while that is the VMs folder:
    /// ~/OmacVM is taken by something else).
    var legacyVMs: [VMConfig] {
        let legacy = Paths.legacyVMsRoot.path
        guard Paths.vmsRoot.standardizedFileURL.path != legacy else { return [] }
        return VMConfig.all().filter { $0.folder.deletingLastPathComponent().path == legacy }
    }

    func moveLegacy() { move(legacyVMs, to: Paths.vmsRoot, setRoot: false) }

    /// Moves the VMs that are not in use (running, being built, or omacvm
    /// working on them); those stay where they are and keep working there.
    func move(_ all: [VMConfig], to target: URL, setRoot: Bool) {
        guard moving == nil, !all.isEmpty else { return }
        let busy = Set(Storage.busyFolders(all.map(\.folder)).map(\.path))
        let list = all.filter { !busy.contains($0.folder.path) }
        let stayed = all.filter { busy.contains($0.folder.path) }.map(\.name)
        let inUse = stayed.isEmpty ? "" : " In use, so not moved: \(stayed.joined(separator: ", ")); shut down and move later."
        guard !list.isEmpty else {
            if setRoot { self.setRoot(target) }
            say((setRoot ? "New VMs go to \(Self.short(target))." : "Nothing moved.") + inUse, error: true)
            return
        }
        let mover = FolderMover()
        self.mover = mover
        moving = Moving(name: list[0].name, phase: "Moving", done: 0, total: 0)
        var last = Date.distantPast
        mover.progress = { phase, done, total in
            // At most ten updates a second reach the window.
            let now = Date()
            guard now.timeIntervalSince(last) > 0.1 || done == total else { return }
            last = now
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.moving?.phase = phase
                    self.moving?.done = done
                    self.moving?.total = total
                }
            }
        }
        let jobs = list.map { ($0.name, $0.folder) }
        DispatchQueue.global(qos: .userInitiated).async {
            var moved = 0
            var failure: String?
            for (name, folder) in jobs {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.moving = Moving(name: name, phase: "Moving", done: 0, total: 0) }
                }
                // Checked again for each VM: one may have started meanwhile.
                if !Storage.busyFolders([folder]).isEmpty {
                    failure = "\(name) started meanwhile; it stays where it is."
                    break
                }
                do {
                    let new = try mover.move(folder, into: target)
                    Storage.excludeFromBackup(new)
                    moved += 1
                } catch StorageError.cancelled {
                    failure = "Cancelled: \(name) stays where it was."
                    break
                } catch {
                    failure = "\(name) was not moved: \(error.localizedDescription)"
                    break
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.mover = nil
                    self.moving = nil
                    if setRoot { self.setRoot(target) } else { self.setRoot(Paths.vmsRoot) }
                    let done = moved == 0 ? "" : "Moved \(moved == 1 ? "1 VM" : "\(moved) VMs") to \(Self.short(target))."
                    if let failure {
                        self.say(done + " " + failure + inUse, error: true)
                    } else {
                        self.say(done + inUse, error: !inUse.isEmpty)
                    }
                    self.onMoved()
                }
            }
        }
    }

    func cancelMove() { mover?.cancel() }

    // MARK: Downloads

    func clearDownloads() {
        if building() || Storage.downloadsInUse(Paths.downloads) {
            say("A build is using the downloads; clear them once it is done.", error: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Clear \(Product.name)'s downloads?"
        alert.informativeText = "\(Storage.format(downloads ?? 0)) in \(Self.short(Paths.downloads)): the live system and prebuilt VMs that builds start from. The next new VM downloads what it needs again. Your VMs are not touched."
        alert.addButton(withTitle: "Clear Downloads")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Storage.clear(Paths.downloads)
            say("Downloads cleared.")
        } catch {
            say("Could not clear all downloads: \(error.localizedDescription)", error: true)
        }
        refresh()
    }
}

/// The VMs folder with its free space and a Change button (setup and settings).
struct VMsFolderRow: View {
    @ObservedObject var storage: StorageModel

    var body: some View {
        LabeledContent("VMs folder") {
            HStack {
                Spacer()
                Text(StorageModel.short(storage.root)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                if let free = storage.free {
                    Text("\(Storage.format(free)) free").foregroundStyle(.secondary)
                }
                Button("Change…") { storage.changeRoot() }
                    .disabled(storage.moving != nil)
            }
        }
        .onAppear { storage.refresh() }
    }
}

/// Settings: the VMs folder, every VM's size, moves, downloads.
struct StorageSection: View {
    @ObservedObject var storage: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage").font(.headline)
            VMsFolderRow(storage: storage)
            ForEach(storage.disconnected, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(storage.vms) { vm in
                HStack {
                    Text(vm.name)
                    if vm.legacy {
                        Text("in the old hidden folder").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(vm.size.map { Storage.format($0) } ?? "…").foregroundStyle(.secondary)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([vm.folder])
                    } label: { Image(systemName: "folder") }
                        .help("Show in Finder")
                }
            }
            if !storage.legacyVMs.isEmpty && storage.moving == nil {
                HStack {
                    Text("2.9 and older kept VMs hidden in ~/Library.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Move to \(StorageModel.short(storage.root))") { storage.moveLegacy() }
                }
            }
            if let m = storage.moving {
                VStack(alignment: .leading, spacing: 4) {
                    if m.total > 0 {
                        ProgressView(value: Double(m.done), total: Double(m.total))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    HStack {
                        Text(m.total > 0
                             ? "\(m.phase) \(m.name): \(Storage.format(m.done)) of \(Storage.format(m.total))"
                             : "Moving \(m.name)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { storage.cancelMove() }
                    }
                }
            }
            HStack {
                Text("Downloads")
                Spacer()
                Text(storage.downloads.map { Storage.format($0) } ?? "…").foregroundStyle(.secondary)
                Button("Clear Downloads") { storage.clearDownloads() }
                    .disabled(storage.moving != nil || (storage.downloads ?? 0) == 0)
            }
            if let n = storage.note {
                Text(n).font(.caption).foregroundStyle(storage.noteIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The VMs folder is on a drive that is not connected, and no VM is found.
struct DriveMissingView: View {
    @ObservedObject var state: AppState

    private var drive: (name: String, root: URL)? {
        Storage.missingDrive(for: Paths.vmsRoot).map { ($0, Paths.vmsRoot) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(drive?.name ?? "The drive") is not connected").font(.title2.bold())
            Text("Your VMs are in \(drive?.root.path ?? "a folder on it"). Connect the drive, then click Try Again.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Use Another Folder…") {
                    state.storage.changeRoot()
                    state.reload()
                }
                Spacer()
                Button("Try Again") { state.reload() }
                    .keyboardShortcut(.defaultAction)
            }
            if let n = state.storage.note {
                Text(n).font(.caption).foregroundStyle(state.storage.noteIsError ? .red : .secondary)
            }
        }
    }
}
