// From try-omarchy (github.com/omacom/try-omarchy), MIT, (c) Try Omarchy contributors:
// macos/Sources/OmarchyVMHelper/NativeBatteryBridge.swift, for OmacVM's port.
import Darwin
import Foundation
import IOKit.ps

/// The Mac's battery to the VM over the virtio port org.omacvm.battery:
/// one JSON snapshot per line (HostBattery.swift) on every change of the
/// Mac's power sources and every 30 seconds. The VM's agent (omacvm-battery)
/// asks for one when it starts ({"type":"refresh"}); nothing is sent before
/// that, so a VM without the agent never fills the port. Any other line
/// from the VM is ignored: it cannot change anything on the Mac.
final class NativeBatteryBridge: @unchecked Sendable {
    static let heartbeatSeconds = 30.0
    static let maximumLineBytes = 4096

    private let descriptor: Int32
    private let stateQueue = DispatchQueue(label: "org.omacvm.battery-bridge")
    private let stopLock = NSLock()
    private var lastSent: HostBatterySnapshot?
    private var guestListening = false
    private var heartbeat: DispatchSourceTimer?
    private let notifications = RunLoopSourceThread()
    private var stopped = false

    init(socketPath: String) throws {
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "battery bridge")
    }

    deinit { stop() }

    static func isRefreshRequest(_ line: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["type"] as? String == "refresh"
    }

    func run() throws {
        startPowerNotifications()
        startHeartbeat()
        var line = Data(), skipping = false
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                var start = 0
                for index in 0..<count where chunk[index] == 0x0A {
                    if !skipping {
                        line.append(contentsOf: chunk[start..<index])
                        // In step with the write, so a VM that floods requests
                        // waits for its answers instead of queueing work here.
                        if Self.isRefreshRequest(line) {
                            stateQueue.sync { guestListening = true; sendOnQueue(forced: true) }
                        }
                    }
                    line.removeAll(keepingCapacity: true)
                    skipping = false
                    start = index + 1
                }
                if !skipping {
                    line.append(contentsOf: chunk[start..<count])
                    if line.count > Self.maximumLineBytes { line.removeAll(); skipping = true }   // dropped, not fatal
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest battery channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else { stopLock.unlock(); return }
        stopped = true
        stopLock.unlock()
        heartbeat?.cancel()
        heartbeat = nil
        notifications.stop()   // ends the notification thread's wait now
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    /// IOKit's power notifications on a thread with its own run loop (run()
    /// blocks this one reading the port).
    private func startPowerNotifications() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                Unmanaged<NativeBatteryBridge>.fromOpaque(context).takeUnretainedValue().send(forced: false)
            }, context)?.takeRetainedValue() else {
                fputs("[battery-bridge] no IOKit power notifications; every 30 s only\n", stderr)
                return
            }
            // The source goes into the loop under the same lock stop() takes,
            // so a stop() at any moment ends this thread at once.
            guard self.notifications.attach(source) else { return }
            self.notifications.run()
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + Self.heartbeatSeconds, repeating: Self.heartbeatSeconds, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.sendOnQueue(forced: true) }   // already on stateQueue
        timer.resume()
        heartbeat = timer
    }

    private func send(forced: Bool) {
        stateQueue.async { [weak self] in self?.sendOnQueue(forced: forced) }
    }

    /// Only on stateQueue. Unchanged snapshots go only when forced.
    private func sendOnQueue(forced: Bool) {
        guard guestListening, !hasStopped() else { return }
        let snapshot = HostBatterySnapshot.capture()
        guard forced || snapshot != lastSent else { return }
        do {
            try NativeBridgeSocket.writeAll(snapshot.line, to: descriptor, label: "battery")
            lastSent = snapshot
        } catch {
            fputs("[battery-bridge] \(error.localizedDescription)\n", stderr)
            stop()
        }
    }
}
