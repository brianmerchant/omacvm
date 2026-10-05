#!/bin/bash
# OmacVM.app's battery bridge, offline: the thread that waits for the Mac's
# power notifications (RunLoopSourceThread) ends at once on stop(), whenever
# stop() comes: before the source is attached, between attach and the wait
# (the run loop is not running yet), and during the hour-long wait. Its
# source fires while it waits. The app's source file is compiled on its own
# with a small test main.
#   src/tests/app-battery.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
S=$R/app/app/Sources/OmacVM
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat > "$T/main.swift" <<'EOF'
import Foundation

var failed = false
func expect(_ what: String, _ ok: Bool) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { failed = true }
}

let firedLock = NSLock()
nonisolated(unsafe) var fired = 0

/// A plain version-0 source; perform counts how often it fired.
func makeSource() -> CFRunLoopSource {
    var context = CFRunLoopSourceContext()
    context.perform = { _ in firedLock.lock(); fired += 1; firedLock.unlock() }
    return CFRunLoopSourceCreate(nil, 0, &context)
}

/// One notification thread like the bridge's: attach, an optional pause at
/// `between` (attach done, loop not running), run. Returns when it ended
/// (`done` signalled), its loop, and whether attach succeeded.
final class Probe: @unchecked Sendable {
    let thread = RunLoopSourceThread()
    let source = makeSource()
    let attached = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var loop: CFRunLoop?
    var attachOK = false
    func start(pauseBetween: Bool) {
        Thread.detachNewThread { [self] in
            attachOK = thread.attach(source)
            loop = CFRunLoopGetCurrent()
            attached.signal()
            if attachOK {
                if pauseBetween { proceed.wait() }
                thread.run()
            }
            done.signal()
        }
    }
    func ended(within seconds: Double) -> Bool { done.wait(timeout: .now() + seconds) == .success }
    var sourceInLoop: Bool { loop.map { CFRunLoopContainsSource($0, source, .defaultMode) } ?? false }
}

// stop() before attach: nothing is added, the thread ends.
do {
    let p = Probe()
    p.thread.stop()
    p.start(pauseBetween: false)
    p.attached.wait()
    expect("stop before attach: attach refuses", !p.attachOK)
    expect("stop before attach: the source is not in the loop", !p.sourceInLoop)
    expect("stop before attach: the thread ends", p.ended(within: 1))
}

// stop() after attach, before the loop runs (the review's case).
do {
    let p = Probe()
    p.start(pauseBetween: true)
    p.attached.wait()
    expect("attach works", p.attachOK)
    expect("attach puts the source in the loop", p.sourceInLoop)
    p.thread.stop()
    expect("stop between attach and the wait: the source is out of the loop", !p.sourceInLoop)
    let t0 = Date()
    p.proceed.signal()
    expect("stop between attach and the wait: the thread ends within 1 s (not the hour)", p.ended(within: 1))
    print("     ended \(Int(Date().timeIntervalSince(t0) * 1000)) ms after it started to wait")
    expect("stop between attach and the wait: no source left in the loop", !p.sourceInLoop)
}

// stop() during the wait; the source fires while the thread waits.
do {
    let p = Probe()
    p.start(pauseBetween: false)
    p.attached.wait()
    Thread.sleep(forTimeInterval: 0.2)
    expect("the thread waits (it has not ended)", !p.ended(within: 0.1))
    firedLock.lock(); let before = fired; firedLock.unlock()
    CFRunLoopSourceSignal(p.source)
    CFRunLoopWakeUp(p.loop!)
    Thread.sleep(forTimeInterval: 0.2)
    firedLock.lock(); let after = fired; firedLock.unlock()
    expect("the source fires on the waiting thread", after == before + 1)
    let t0 = Date()
    p.thread.stop()
    expect("stop during the wait: the thread ends within 1 s", p.ended(within: 1))
    print("     ended \(Int(Date().timeIntervalSince(t0) * 1000)) ms after stop")
    p.thread.stop()
    expect("a second stop does nothing", p.thread.isStopped)
}

// stop() at random moments around the thread's start: every thread ends.
do {
    var hung = 0
    for _ in 0..<300 {
        let p = Probe()
        p.start(pauseBetween: false)
        usleep(UInt32.random(in: 0...3000))
        p.thread.stop()
        if !p.ended(within: 2) { hung += 1 }
    }
    expect("300 stops at random moments: every thread ends within 2 s (hung: \(hung))", hung == 0)
}

if failed { print("app-battery: FAILED"); exit(1) }
print("app-battery: all passed")
EOF

swiftc -O -swift-version 5 -o "$T/test" "$S/RunLoopSourceThread.swift" "$T/main.swift" || { echo "app-battery: build failed"; exit 1; }
"$T/test"
