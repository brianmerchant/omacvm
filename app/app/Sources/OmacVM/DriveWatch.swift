import AppKit
import Foundation

/// Watches the drive a running VM's folder is on. A drive that goes away
/// (unplugged, a dropped USB link, ejected by force) takes the VM's disk
/// with it: QEMU's open files then fail and nothing it writes lands
/// anywhere. Three signals, whichever comes first: the folder's vnode is
/// revoked (kqueue NOTE_REVOKE: its file system was unmounted), macOS says
/// the volume unmounted, or a poll every 2 s finds its file system no longer
/// mounted (DriveWatch.mounted). The folder only moving on its drive (Finder)
/// or the drive being renamed (its mount point moves) is no signal. `gone`
/// runs once, on the main queue, with the drive's name.
/// Foundation, AppKit and Storage only: src/tests/app-drive-drop.sh compiles
/// it alone and drops a real disk image under it.
final class DriveWatch: @unchecked Sendable {
    let name: String
    let mount: URL
    private let device: dev_t
    private let queue = DispatchQueue(label: "org.omacvm.drive-watch")
    /// The 2 s poll's own queue.
    private let pollQueue = DispatchQueue(label: "org.omacvm.drive-watch.poll")
    private let lock = NSLock()
    // Under `lock`: signals and the watch can end on any thread.
    private var gone: ((String) -> Void)?
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    /// nil when the folder or its volume cannot be read now.
    init?(folder: URL, gone: @escaping (String) -> Void) {
        guard let v = try? folder.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey]),
              let mount = v.volume?.standardizedFileURL,
              let device = Storage.device(mount) else { return nil }
        self.mount = mount
        self.device = device
        name = v.volumeName ?? mount.lastPathComponent
        self.gone = gone
        // O_EVTONLY: watching never keeps the drive from being ejected.
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .revoke, queue: queue)
            s.setEventHandler { [weak self] in self?.fire() }
            s.setCancelHandler { close(fd) }
            source = s
            s.resume()
        }
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in
            guard let self, !Self.mounted(self.device) else { return }
            self.fire()
        }
        timer = t
        t.resume()
        let path = mount.path
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            guard url?.standardizedFileURL.path == path else { return }
            self?.fire()
        }
    }

    deinit { stop() }

    /// No more signals (QEMU ended, or the drive went).
    func stop() { _ = end() }

    /// Ends the watch; the callback if it had not ended yet.
    private func end() -> ((String) -> Void)? {
        lock.lock()
        let g = gone, s = source, t = timer, o = observer
        gone = nil; source = nil; timer = nil; observer = nil
        lock.unlock()
        s?.cancel()
        t?.cancel()
        if let o { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        return g
    }

    private func fire() {
        guard let g = end() else { return }
        let n = name
        DispatchQueue.main.async { g(n) }
    }

    /// A file system with this device is mounted. Read from the mount table
    /// (MNT_NOWAIT: no I/O on a drive that may hang), by device and not by
    /// path: a renamed drive moves its mount point (/Volumes/NEW) but stays;
    /// a drive gone leaves no entry, and another drive mounted under the old
    /// name has another device. The device is st_dev, which macOS gives as
    /// the file system's f_fsid.val[0].
    static func mounted(_ device: dev_t) -> Bool {
        let n = getfsstat(nil, 0, MNT_NOWAIT)
        // Unreadable now: say mounted (the revoke and unmount signals stay).
        guard n > 0 else { return true }
        var list: [statfs] = Array(repeating: statfs(), count: Int(n) + 8)
        let got = list.withUnsafeMutableBufferPointer {
            getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        }
        guard got > 0 else { return true }
        return list.prefix(Int(got)).contains { $0.f_fsid.val.0 == device }
    }
}
