// dispcap SECONDS [DISPLAY-NAME-PART]: how often a display's picture changes (WindowServer frames per second that
// ScreenCaptureKit reports as complete, i.e. new content), default the built-in display. A small capture (1/8 size)
// so the capture itself costs little. Prints JSON: complete_per_s, idle_per_s, gap percentiles.
import Foundation
import AppKit
_ = NSApplication.shared
import ScreenCaptureKit
import CoreMedia

let args = CommandLine.arguments
let secs = Double(args[1])!, namePart = args.count > 2 ? args[2] : "Built-in"
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ms(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e6 }
final class Out: NSObject, SCStreamOutput {
  var complete: [Double] = [], idle = 0
  let lock = NSLock()
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }
    let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
    let status = (att[.status] as? Int) ?? -1, dt = (att[.displayTime] as? UInt64) ?? 0
    lock.lock()
    if status == SCFrameStatus.complete.rawValue { complete.append(ms(dt)) } else if status == SCFrameStatus.idle.rawValue { idle += 1 }
    lock.unlock()
  }
}
guard let screen = NSScreen.screens.first(where: { $0.localizedName.contains(namePart) }),
      let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
  print("no display \(namePart)"); exit(1)
}
let sem = DispatchSemaphore(value: 0)
var stream: SCStream?
let out = Out()
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, err in
  guard let content = content, let d = content.displays.first(where: { $0.displayID == did }) else {
    print("no display: \(String(describing: err))"); exit(1)
  }
  let c = SCStreamConfiguration()
  c.width = max(64, d.width / 8); c.height = max(64, d.height / 8)
  c.minimumFrameInterval = CMTime(value: 1, timescale: 240)
  c.queueDepth = 8; c.showsCursor = true
  let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: c, delegate: nil)
  try! s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "cap"))
  s.startCapture { e in if let e = e { print("start failed: \(e)"); exit(1) }; sem.signal() }
  stream = s
}
sem.wait()
Thread.sleep(forTimeInterval: secs)
let done = DispatchSemaphore(value: 0)
stream!.stopCapture { _ in done.signal() }
done.wait()
out.lock.lock()
let t = out.complete
var gaps: [Double] = []
for i in 1..<max(1, t.count) { gaps.append(t[i] - t[i-1]) }
gaps.sort()
func p(_ q: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(q * Double(gaps.count)))] }
print("{\"display\":\"\(screen.localizedName)\",\"seconds\":\(secs),\"complete_per_s\":\(Double(t.count) / secs),\"idle_per_s\":\(Double(out.idle) / secs),\"gap_ms_p10\":\(p(0.1)),\"gap_ms_p50\":\(p(0.5)),\"gap_ms_p90\":\(p(0.9))}")
