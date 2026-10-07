import AppKit
import OmacVMUSB
import SwiftUI

/// USB devices while one VM runs with the switch on (docs/usb.md): the
/// Mac's devices (USBWatch), the decisions (USBSession), the question
/// (USBAlertAsker) and QEMU (QMP, on a queue of its own). Starts once QEMU's
/// control socket answers, stops when QEMU ends (QEMU gives every device
/// back to the Mac as it exits). Main thread.
@MainActor
final class USBRun: ObservableObject {
    let config: VMConfig
    let requestName: String
    private let pid: pid_t
    private let log: (String) -> Void
    private let watch = USBWatch()
    private let asker = USBAlertAsker()
    private var session: USBSession?
    private var observers: [NSObjectProtocol] = []
    private var request: NSObjectProtocol?
    private var panel: NSPanel?
    private var stopped = false

    /// What the list shows (USBDeviceList).
    @Published private(set) var rows = USBListRows()
    private var devices: [UInt32: USBDevice] = [:]

    init(config: VMConfig, qemuPID: pid_t, log: @escaping (String) -> Void) {
        self.config = config
        self.pid = qemuPID
        self.log = log
        requestName = Self.requestName()
    }

    nonisolated static func requestName() -> String {
        "\(Bundle.main.bundleIdentifier ?? "org.omacvm.app").usb.\(getpid())"
    }

    /// For QEMU's "USB Devices…" menu item (OMACVM_USB_REQUEST): it posts
    /// this name and the list opens.
    func listen() {
        request = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(requestName), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showList() }
        }
    }

    /// Waits for QEMU's control socket (up to 60 s), then watches the devices.
    func start() {
        let path = config.qmpSocket.path
        Task { [weak self] in
            for _ in 0..<120 {
                let up = await Task.detached { (try? USBQMPSocket(path: path).execute("query-status", nil)) != nil }.value
                guard let self, !self.stopped else { return }
                if up {
                    self.begin()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self?.log("OmacVM: USB: QEMU's control socket did not answer: no device is asked about this start")
        }
    }

    private func begin() {
        let folder = config.folder
        let memory = USBMemory.load(folder: folder) { [weak self] in self?.log($0) }
        let machine = USBQMPMachine(socketPath: config.qmpSocket.path)
        asker.qemuPID = { [pid] in pid }
        let s = USBSession(vmName: config.name, memory: memory, machine: machine, asker: asker, clock: MainClock(),
                           save: { [weak self] m in
                               do { try m.save(folder: folder) } catch {
                                   self?.log("OmacVM: USB: could not save \(USBMemory.fileName): \(error.localizedDescription)")
                               }
                           },
                           log: { [weak self] in self?.log($0) })
        s.onChange = { [weak self] in self?.refreshRows() }
        session = s
        s.inFront = inFront
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.session?.inFront = self.inFront
            }
        })
        watch.onPlug = { [weak self] d in
            self?.devices[d.location] = d
            self?.session?.plugged(d)
            self?.refreshRows()
        }
        watch.onUnplug = { [weak self] loc in
            self?.devices[loc] = nil
            self?.session?.unplugged(location: loc)
            self?.refreshRows()
        }
        watch.start()
    }

    /// The VM's window is in front, or this app is (its question or list):
    /// only then does a question come up.
    private var inFront: Bool {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return front == pid || front == getpid()
    }

    /// QEMU ended: nothing more to ask; the Mac has its devices back.
    func stop() {
        guard !stopped else { return }
        stopped = true
        watch.stop()
        session?.stop()
        session = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if let request { DistributedNotificationCenter.default().removeObserver(request) }
        request = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func refreshRows() {
        guard let s = session else { return }
        rows = USBListRows.make(memory: s.memory, devices: devices.values.sorted { $0.location < $1.location },
                                states: s.plugs.mapValues(\.state), vmName: config.name)
    }

    // MARK: The list while the VM runs

    func setPlan(_ plan: USBPlan, row: USBListRows.Row) {
        if let key = row.key { session?.setPlan(plan, key: key) } else if let d = row.device { session?.setPlan(plan, for: d) }
    }

    func forget(_ row: USBListRows.Row) {
        if let key = row.key { session?.forget(key: key) }
    }

    func connect(_ row: USBListRows.Row) {
        if let d = row.device { session?.connectNow(location: d.location) }
    }

    func disconnect(_ row: USBListRows.Row) {
        if let d = row.device { session?.disconnectNow(location: d.location) }
    }

    /// A floating panel over the VM (on its full-screen Space too); closing
    /// it gives the VM's window the keys back.
    func showList() {
        guard !stopped else { return }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
            p.title = "USB Devices"
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.contentViewController = NSHostingController(rootView: USBDeviceList(source: .running(self), vmName: config.name) { [weak self] in
                self?.closeList()
            })
            p.center()
            panel = p
        }
        refreshRows()
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func closeList() {
        panel?.orderOut(nil)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}

/// The session's timers on the main queue.
final class MainClock: USBClock {
    func after(_ seconds: Double, _ run: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: run)
    }
}

/// One short QMP connection per command: QEMU's socket serves one client at
/// a time, and the app's other users (the Vulkan start watch, the fast
/// network, sleep) must not wait for this one.
struct USBQMPSocket: USBQMPTransport {
    let path: String
    func execute(_ command: String, _ arguments: [String: Any]?) throws -> [String: Any] {
        let q = try QMPConnection(socketPath: path, identifierPrefix: "omacvm-usb")
        defer { q.close() }
        return try q.execute(command, arguments: arguments, timeoutMilliseconds: 3_000)
    }
}

/// The VM over QMP: one call at a time, in order, off the main thread;
/// answers back on the main thread.
final class USBQMPMachine: USBMachine {
    private let qmp: USBQMPSocket
    private let queue = DispatchQueue(label: "org.omacvm.usb-qmp", qos: .userInitiated)

    init(socketPath: String) { qmp = USBQMPSocket(path: socketPath) }

    func attach(_ device: USBDevice, done: @escaping (USBAttachResult) -> Void) {
        queue.async { [qmp] in
            let r = USBQMP.attach(device, over: qmp)
            DispatchQueue.main.async { done(r) }
        }
    }

    func detach(_ device: USBDevice, done: @escaping (Bool) -> Void) {
        queue.async { [qmp] in
            let r = USBQMP.detach(location: device.location, over: qmp)
            DispatchQueue.main.async { done(r) }
        }
    }

    func isAttached(_ device: USBDevice, done: @escaping (Bool) -> Void) {
        queue.async { [qmp] in
            let r = (try? USBQMP.attached(over: qmp))?.contains(USBQMP.qemuID(location: device.location)) ?? false
            DispatchQueue.main.async { done(r) }
        }
    }
}
