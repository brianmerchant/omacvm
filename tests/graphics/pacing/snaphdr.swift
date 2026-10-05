// snaphdr WINDOWID: one ScreenCaptureKit frame of the window as half float in extended linear Display P3
// (1.0 = SDR white); prints the brightest value and samples across the middle row. Also prints the
// screen's current EDR headroom (>1 while something on it shows HDR).
import Foundation
import AppKit
import ScreenCaptureKit
_ = NSApplication.shared
let wid = CGWindowID(CommandLine.arguments[1])!
let sem = DispatchSemaphore(value: 0)
final class Grab: NSObject, SCStreamOutput {
  var done = false
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard !done, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!
    func px(_ x: Int, _ y: Int) -> (Float, Float, Float) {
      let p = (base + y * bpr + x * 8).assumingMemoryBound(to: Float16.self)
      return (Float(p[0]), Float(p[1]), Float(p[2]))
    }
    var mx: Float = 0
    for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) { let v = px(x, y); mx = max(mx, v.0, v.1, v.2) } }
    var row: [String] = []
    for i in 0..<9 { let v = px((i * 2 + 1) * w / 18, h * 2 / 3); row.append(String(format: "%.2f", max(v.0, v.1, v.2))) }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    print("max \(mx) row \(row.joined(separator: " "))")
    done = true; sem.signal()
  }
}
let g = Grab()
var stream: SCStream?
SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, _ in
  let win = c!.windows.first { $0.windowID == wid }!
  let cfg = SCStreamConfiguration()
  cfg.width = Int(win.frame.width); cfg.height = Int(win.frame.height)
  cfg.pixelFormat = kCVPixelFormatType_64RGBAHalf
  cfg.colorSpaceName = CommandLine.arguments.count > 2 ? (CommandLine.arguments[2] == "pq" ? CGColorSpace.itur_2100_PQ : CGColorSpace.extendedLinearSRGB) : CGColorSpace.extendedLinearDisplayP3
  cfg.captureDynamicRange = .hdrLocalDisplay
  cfg.showsCursor = false
  let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
  try! s.addStreamOutput(g, type: .screen, sampleHandlerQueue: DispatchQueue(label: "g"))
  s.startCapture { e in if let e = e { print("start: \(e)") } }
  stream = s
}
_ = sem.wait(timeout: .now() + 5)
for s in NSScreen.screens { print("screen", s.localizedName, "edr now", s.maximumExtendedDynamicRangeColorComponentValue, "potential", s.maximumPotentialExtendedDynamicRangeColorComponentValue) }
