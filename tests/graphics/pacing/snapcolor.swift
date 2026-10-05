// snapcolor WINDOWID: one ScreenCaptureKit frame of the window, converted to Display P3 (and sRGB);
// prints the colour of six vertical bars (colors.html) at mid height.
import Foundation
import AppKit
import ScreenCaptureKit
_ = NSApplication.shared
let wid = CGWindowID(CommandLine.arguments[1])!
final class Grab: NSObject, SCStreamOutput {
  var done = false; let space: CFString; let sem: DispatchSemaphore
  init(_ s: CFString, _ sem: DispatchSemaphore) { space = s; self.sem = sem }
  func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard !done, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var out: [String] = []
    for i in 0..<6 {
      let x = Int((Double(i) + 0.5) * Double(w) / 6), y = h * 2 / 3
      let p = base + y * bpr + x * 4
      out.append("(\(p[2]),\(p[1]),\(p[0]))")
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    print(space, out.joined(separator: " "))
    done = true; sem.signal()
  }
}
for space in [CGColorSpace.displayP3, CGColorSpace.sRGB] {
  let sem = DispatchSemaphore(value: 0)
  var stream: SCStream?
  let g = Grab(space, sem)
  SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { c, _ in
    let win = c!.windows.first { $0.windowID == wid }!
    let cfg = SCStreamConfiguration()
    cfg.width = Int(win.frame.width); cfg.height = Int(win.frame.height)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA; cfg.colorSpaceName = space; cfg.showsCursor = false
    let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg, delegate: nil)
    try! s.addStreamOutput(g, type: .screen, sampleHandlerQueue: DispatchQueue(label: "g"))
    s.startCapture { _ in }
    stream = s
  }
  _ = sem.wait(timeout: .now() + 5)
  stream?.stopCapture { _ in }
}
