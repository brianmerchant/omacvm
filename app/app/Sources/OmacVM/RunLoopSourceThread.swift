import Foundation

/// One run loop source on a thread of its own until stop() (the battery
/// bridge's IOKit power notifications). attach() and stop() share one lock:
/// stop() either comes first (attach() then adds nothing) or finds the source
/// already in the loop and removes it. A loop without a source returns at
/// once, so stop() ends run() even before the loop has started waiting.
/// Tested by src/tests/app-battery.sh.
final class RunLoopSourceThread: @unchecked Sendable {
    private let lock = NSLock()
    private var source: CFRunLoopSource?
    private var loop: CFRunLoop?
    private var stopped = false

    /// On the thread that calls run() next. False once stop() has run.
    func attach(_ source: CFRunLoopSource) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        let loop = CFRunLoopGetCurrent()!
        CFRunLoopAddSource(loop, source, .defaultMode)
        self.source = source
        self.loop = loop
        return true
    }

    /// Runs this thread's loop until stop(). The hour-long wait only keeps
    /// the thread from waking for nothing; stop() ends it at once.
    func run() {
        while !isStopped { CFRunLoopRunInMode(.defaultMode, 3600, false) }
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// From any thread; a second call does nothing.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let source = self.source, loop = self.loop
        self.source = nil
        self.loop = nil
        lock.unlock()
        if let source, let loop {
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            CFRunLoopStop(loop)
        }
    }
}
