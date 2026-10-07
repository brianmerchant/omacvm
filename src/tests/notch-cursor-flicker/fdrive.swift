// fdrive LOG STEP... : posts HID-level mouseMoved events like a real mouse
// (location + integer deltas, 125 Hz) and logs each on the mach clock.
// Steps:  goto X Y              one jump (one event)
//         line X Y MS           straight from where the cursor is to X,Y in MS
//         wait MS
//         cross X YA YB MS DWELL N   N times: YA -> YB in MS, wait DWELL, back, wait DWELL
//         hline Y XA XB MS DWELL N   along a row: XA -> XB and back
import Foundation
import CoreGraphics
import QuartzCore

let a = Array(CommandLine.arguments.dropFirst())
guard !a.isEmpty else { exit(2) }
FileManager.default.createFile(atPath: a[0], contents: nil)
let log = FileHandle(forWritingAtPath: a[0])!
let src = CGEventSource(stateID: .hidSystemState)
func cur() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }
var pos = cur()
func L(_ s: String) { log.write(String(format: "%.4f D %@\n", CACurrentMediaTime(), s).data(using: .utf8)!) }
func post(_ p: CGPoint) {
    let dx = Int64((p.x - pos.x).rounded()), dy = Int64((p.y - pos.y).rounded())
    let np = CGPoint(x: pos.x + Double(dx), y: pos.y + Double(dy))
    guard let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: np, mouseButton: .left) else { return }
    e.setIntegerValueField(.mouseEventDeltaX, value: dx)
    e.setIntegerValueField(.mouseEventDeltaY, value: dy)
    e.post(tap: .cghidEventTap)
    pos = np
    L(String(format: "move %.0f,%.0f d=%lld,%lld", np.x, np.y, dx, dy))
}
func sleepUntil(_ t: Double) { let d = t - CACurrentMediaTime(); if d > 0 { usleep(useconds_t(d * 1e6)) } }
func line(to p: CGPoint, ms: Double) {
    let start = pos, t0 = CACurrentMediaTime(), n = max(1, Int((ms / 8).rounded()))
    for i in 1...n {
        let f = Double(i) / Double(n)
        sleepUntil(t0 + Double(i) * ms / 1000 / Double(n))
        post(CGPoint(x: start.x + (p.x - start.x) * f, y: start.y + (p.y - start.y) * f))
    }
}
func wait(_ ms: Double) { usleep(useconds_t(ms * 1000)) }
var i = 1
func D(_ k: Int) -> Double { Double(a[i + k])! }
while i < a.count {
    switch a[i] {
    case "goto": L("step goto"); post(CGPoint(x: D(1), y: D(2))); i += 3
    case "line": L("step line"); line(to: CGPoint(x: D(1), y: D(2)), ms: D(3)); i += 4
    case "wait": wait(D(1)); i += 2
    case "cross":
        let x = D(1), ya = D(2), yb = D(3), ms = D(4), dwell = D(5), n = Int(D(6))
        line(to: CGPoint(x: x, y: ya), ms: 200); wait(dwell)
        for k in 0..<n {
            L("step cross \(k) up"); line(to: CGPoint(x: x, y: yb), ms: ms); wait(dwell)
            L("step cross \(k) down"); line(to: CGPoint(x: x, y: ya), ms: ms); wait(dwell)
        }
        i += 7
    case "hline":
        let y = D(1), xa = D(2), xb = D(3), ms = D(4), dwell = D(5), n = Int(D(6))
        line(to: CGPoint(x: xa, y: y), ms: 200); wait(dwell)
        for k in 0..<n {
            L("step hline \(k) right"); line(to: CGPoint(x: xb, y: y), ms: ms); wait(dwell)
            L("step hline \(k) left"); line(to: CGPoint(x: xa, y: y), ms: ms); wait(dwell)
        }
        i += 7
    default: FileHandle.standardError.write("bad step \(a[i])\n".data(using: .utf8)!); exit(2)
    }
}
L("done")
