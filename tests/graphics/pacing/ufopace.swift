// ufopace WINDOWID SECONDS OUT.json [Y0 Y1 X0 X1]: capture a window with ScreenCaptureKit (up to 240 fps) while
// testufo.com runs in it, and measure how far the UFO in one lane moved between WindowServer frames.
// Y0..Y1 / X0..X1: the lane as fractions of the captured window (default 0.47..0.51 / 0.05..0.70).
// Per frame: column luminance profile of the band; background = per-column median over all frames; shift =
// best cross-correlation of the foreground (profile - background) of consecutive frames, 0..60 px.
// Output: shift histogram in units of the median nonzero shift (1 = each refresh a new frame, 0 = repeat,
// 2 = a frame skipped), new frames per second, display gaps.
import Foundation
import AppKit
_ = NSApplication.shared
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let a = CommandLine.arguments
let wid = CGWindowID(a[1])!, secs = Double(a[2])!, outPath = a[3]
let y0 = a.count > 4 ? Double(a[4])! : 0.47, y1 = a.count > 5 ? Double(a[5])! : 0.51
let x0 = a.count > 6 ? Double(a[6])! : 0.05, x1 = a.count > 7 ? Double(a[7])! : 0.70
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ms(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6 }

final class Out: NSObject, SCStreamOutput {
  var rows: [(Double, [Float])] = []
  let lock = NSLock()
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }
    let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
    guard (att[.status] as? Int) == SCFrameStatus.complete.rawValue, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    let dt = (att[.displayTime] as? UInt64) ?? 0
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    let ya = Int(Double(h) * y0), yb = Int(Double(h) * y1), xa = Int(Double(w) * x0), xb = Int(Double(w) * x1)
    var prof = [Float](repeating: 0, count: xb - xa)
    for y in stride(from: ya, to: yb, by: 1) {
      let row = base + y * bpr
      for x in xa..<xb { let p = row + x * 4; prof[x - xa] += Float(Int(p[0]) + Int(p[1]) * 2 + Int(p[2])) }
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    if ProcessInfo.processInfo.environment["DBG"] != nil && rows.isEmpty {
      let img = CIImage(cvPixelBuffer: pb); let rep = NSBitmapImageRep(ciImage: img)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outPath + ".png"))
      print("frame \(w)x\(h) band y \(ya)-\(yb) x \(xa)-\(xb)")
    }
    lock.lock(); rows.append((ms(dt), prof)); lock.unlock()
  }
}

let sem = DispatchSemaphore(value: 0)
var stream: SCStream?
let out = Out()
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
  guard let content = content, let win = content.windows.first(where: { $0.windowID == wid }) else {
    print("no window: \(String(describing: err))"); exit(1)
  }
  let f = SCContentFilter(desktopIndependentWindow: win)
  let c = SCStreamConfiguration()
  c.width = Int(win.frame.width); c.height = Int(win.frame.height)
  c.minimumFrameInterval = CMTime(value: 1, timescale: 240)
  c.queueDepth = 8; c.showsCursor = false; c.pixelFormat = kCVPixelFormatType_32BGRA
  let s = SCStream(filter: f, configuration: c, delegate: nil)
  try! s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap", qos: .userInteractive))
  s.startCapture { e in if let e = e { print("start failed: \(e)"); exit(1) }; sem.signal() }
  stream = s
}
sem.wait()
Thread.sleep(forTimeInterval: secs)
stream!.stopCapture { _ in sem.signal() }
sem.wait()
out.lock.lock(); let rows = out.rows; out.lock.unlock()
guard rows.count > 10 else { print("{\"error\":\"too few frames\",\"captured\":\(rows.count)}"); exit(1) }
let n = rows[0].1.count
var bg = [Float](repeating: 0, count: n)
for x in 0..<n { var col = rows.map { $0.1[x] }; col.sort(); bg[x] = col[col.count / 2] }
let fg = rows.map { r in (0..<n).map { abs(r.1[$0] - bg[$0]) } }
var shifts: [Int] = []
for i in 1..<fg.count {
  var best = 0; var bestv: Float = -1
  for s in 0...60 {
    var v: Float = 0
    for x in 0..<(n - s) { v += fg[i - 1][x] * fg[i][x + s] }
    v /= Float(n - s)
    if v > bestv { bestv = v; best = s }
  }
  shifts.append(best)
}
let nz = shifts.filter { $0 > 2 }.sorted()
let unit = nz.isEmpty ? 1.0 : Double(nz[nz.count / 2])
var hist: [Int: Int] = [:]
for s in shifts { hist[Int((Double(s) / unit).rounded()), default: 0] += 1 }
let span = rows.last!.0 - rows.first!.0
var gaps = (1..<rows.count).map { rows[$0].0 - rows[$0 - 1].0 }; gaps.sort()
func p(_ q: Double) -> Double { gaps[min(gaps.count - 1, Int(q * Double(gaps.count)))] }
let newFrames = shifts.filter { $0 > 2 }.count
let movedUnits = shifts.reduce(0) { $0 + Double($1) } / unit
// rows: t, shift
var text = ""; for (i, r) in rows.enumerated() { text += "{\"t\":\(r.0),\"shift\":\(i == 0 ? 0 : shifts[i - 1])}\n" }
try? text.write(toFile: outPath, atomically: true, encoding: .utf8)
print("{\"captured\":\(rows.count),\"span_ms\":\(Int(span)),\"wsframes_per_s\":\(Double(rows.count - 1) * 1000 / span),\"new_frames_per_s\":\(Double(newFrames) * 1000 / span),\"content_fps\":\(movedUnits * 1000 / span),\"unit_px\":\(unit),\"steps\":{\(hist.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ","))},\"gap_ms_p50\":\(p(0.5)),\"gap_p99\":\(p(0.99)),\"gap_max\":\(gaps.last!)}")
