// sckpace WINDOWID SECONDS OUT.jsonl: capture a window with ScreenCaptureKit at up to 240 frames a second,
// decode the frame counter pacing.html draws, print pacing statistics as JSON (counter_steps: how far the
// counter moved between WindowServer frames; 1 = every guest frame shown once).
// QMP=/path/to/qmp.sock: also press F13 every 200-300 ms through QMP and print key -> screen latency first.
// DBG=1 prints the sampled cell brightness of each frame.
import Foundation
import AppKit
_ = NSApplication.shared
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let args = CommandLine.arguments
let pid = pid_t(args[1])!, secs = Double(args[2])!, outPath = args[3]
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ms(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6 }

final class Out: NSObject, SCStreamOutput {
  var rows: [(Double, Int, Int)] = []   // display time ms, counter (-1 unknown), status
  var marks: [(Double, Int)] = []       // display time ms, latency marker (0/1)
  let lock = NSLock()
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }
    let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
    let status = (att[.status] as? Int) ?? -1
    let dt = (att[.displayTime] as? UInt64) ?? 0
    var counter = -1
    if let pb = CMSampleBufferGetImageBuffer(sb) {
      CVPixelBufferLockBaseAddress(pb, .readOnly)
      let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
      let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
      // The page fills the guest's 16:9 output; the window's title bar sits above it.
      let contentH = Double(w) * 9.0 / 16.0
      let top = Double(h) - contentH
      let cell = Double(w) / 24.0
      func lum(_ i: Int) -> Int {
        let x = Int((Double(i) + 1.5) * cell), y = Int(top + 1.5 * cell)
        guard x < w, y < h, y >= 0 else { return 0 }
        let p = base + y * bpr + x * 4
        return (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
      }
      if ProcessInfo.processInfo.environment["DBG"] != nil { print(w, h, bpr, (0..<18).map{lum($0)}) }
      func lumAt(_ cx: Double, _ cy: Double) -> Int {
        let x = Int(cx * cell), y = Int(top + cy * cell)
        guard x < w, y < h, y >= 0 else { return 0 }
        let p = base + y * bpr + x * 4
        return (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3
      }
      if lum(0) > 200 && lum(17) < 60 && status == SCFrameStatus.complete.rawValue {
        lock.lock(); marks.append((ms(dt), lumAt(1.5, 2.7) > 128 ? 1 : 0)); lock.unlock()
      }
      if lum(0) > 200 && lum(17) < 60 {
        var v = 0
        for b in 0..<16 { if lum(b + 1) > 128 { v |= 1 << b } }
        counter = v
      }
      CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    }
    lock.lock(); rows.append((ms(dt), counter, status)); lock.unlock()
  }
}

let sem = DispatchSemaphore(value: 0)
var stream: SCStream?
let out = Out()
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, err in
  guard let content = content, let win = content.windows.first(where: { $0.windowID == CGWindowID(pid) }) else {
    print("no window: \(String(describing: err))"); exit(1)
  }
  let f = SCContentFilter(desktopIndependentWindow: win)
  let c = SCStreamConfiguration()
  c.width = Int(win.frame.width); c.height = Int(win.frame.height)
  c.minimumFrameInterval = CMTime(value: 1, timescale: 240)
  c.queueDepth = 8; c.showsCursor = false; c.pixelFormat = kCVPixelFormatType_32BGRA
  let s = SCStream(filter: f, configuration: c, delegate: nil)
  try! s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
  s.startCapture { e in if let e = e { print("start failed: \(e)"); exit(1) }; sem.signal() }
  stream = s
}
sem.wait()
var sends: [Double] = []
if let qmp = ProcessInfo.processInfo.environment["QMP"] {
  // Latency mode: press a key every 250 ms (+ jitter) through QMP; the page flips a marker cell.
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
  let pathBytes = Array(qmp.utf8CString)
  withUnsafeMutableBytes(of: &addr.sun_path) { dst in
    pathBytes.withUnsafeBytes { src in _ = memcpy(dst.baseAddress!, src.baseAddress!, min(dst.count, src.count)) }
  }
  let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  if ok != 0 { print("qmp connect failed"); exit(1) }
  var buf = [UInt8](repeating: 0, count: 65536)
  func send(_ s: String) { _ = s.withCString { write(fd, $0, strlen($0)) }; usleep(2000); _ = read(fd, &buf, buf.count) }
  _ = read(fd, &buf, buf.count)
  send("{\"execute\":\"qmp_capabilities\"}\n")
  let end = Date().addingTimeInterval(secs)
  while Date() < end {
    usleep(UInt32(200000 + arc4random_uniform(100000)))
    let down = "{\"execute\":\"input-send-event\",\"arguments\":{\"events\":[{\"type\":\"key\",\"data\":{\"down\":true,\"key\":{\"type\":\"qcode\",\"data\":\"f13\"}}}]}}\n"
    let t = ms(mach_absolute_time())
    _ = down.withCString { write(fd, $0, strlen($0)) }
    sends.append(t)
    usleep(30000); _ = read(fd, &buf, buf.count)
    send(down.replacingOccurrences(of: "\"down\":true", with: "\"down\":false"))
  }
} else {
  Thread.sleep(forTimeInterval: secs)
}
stream!.stopCapture { _ in sem.signal() }
sem.wait()

out.lock.lock(); let rows = out.rows; let marks = out.marks; out.lock.unlock()
if !sends.isEmpty {
  // Each marker flip after a key press: display time minus send time.
  var lat: [Double] = []
  var prev = marks.first?.1 ?? 0
  var si = 0
  for m in marks {
    if m.1 != prev {
      while si + 1 < sends.count && sends[si + 1] < m.0 { si += 1 }
      if si < sends.count && sends[si] < m.0 { lat.append(m.0 - sends[si]) }
      prev = m.1
    }
  }
  lat.sort()
  func q(_ x: Double) -> Double { lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(x * Double(lat.count)))] }
  print("{\"keys\":\(sends.count),\"flips\":\(lat.count),\"latency_ms_p50\":\(q(0.5)),\"p10\":\(q(0.1)),\"p90\":\(q(0.9)),\"max\":\(lat.last ?? 0),\"mean\":\(lat.isEmpty ? 0 : lat.reduce(0,+)/Double(lat.count))}")
}
var text = ""
for r in rows { text += "{\"t\":\(r.0),\"n\":\(r.1),\"st\":\(r.2)}\n" }
try! text.write(toFile: outPath, atomically: true, encoding: .utf8)
// Statistics over complete frames with a decoded counter.
let good = rows.filter { $0.2 == SCFrameStatus.complete.rawValue && $0.1 >= 0 }
var steps: [Int: Int] = [:], gaps: [Double] = []
for i in 1..<max(1, good.count) {
  let d = (good[i].1 - good[i-1].1 + 65536) % 65536
  steps[min(d, 9), default: 0] += 1
  gaps.append(good[i].0 - good[i-1].0)
}
gaps.sort()
func p(_ q: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(q * Double(gaps.count)))] }
let span = (good.last?.0 ?? 0) - (good.first?.0 ?? 0)
let shown = good.count
let newFrames = (good.last?.1 ?? 0) - (good.first?.1 ?? 0)
print("{\"captured\":\(rows.count),\"complete_decoded\":\(shown),\"span_ms\":\(Int(span)),\"shown_fps\":\(span > 0 ? Double(shown-1)*1000/span : 0),\"guest_frames_advanced\":\(newFrames),\"counter_steps\":{\(steps.sorted{$0.key<$1.key}.map{"\"\($0.key)\":\($0.value)"}.joined(separator: ","))},\"gap_ms_p50\":\(p(0.5)),\"gap_p1\":\(p(0.01)),\"gap_p99\":\(p(0.99)),\"gap_max\":\(gaps.last ?? 0)}")
