// fcap SECONDS OUT.raw X Y W H : records a region of the main display (points,
// top-left origin) at 60 fps WITH the cursor (ScreenCaptureKit), 1 px per point.
// OUT.raw: per complete frame a 24-byte header (double t = display time on the
// mach clock in s, int32 w, int32 h, int32 bytesPerRow, int32 0) + BGRA rows.
// Lines on stdout: I,<key>,<value>.
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

let a = CommandLine.arguments
guard a.count == 7, let secs = Double(a[1]), let rx = Double(a[3]), let ry = Double(a[4]),
      let rw = Int(a[5]), let rh = Int(a[6]) else {
    FileHandle.standardError.write("usage: fcap SECONDS OUT.raw X Y W H\n".data(using: .utf8)!); exit(2)
}
FileManager.default.createFile(atPath: a[2], contents: nil)
let out = FileHandle(forWritingAtPath: a[2])!
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
let q = DispatchQueue(label: "fcap")

final class Sink: NSObject, SCStreamOutput, SCStreamDelegate {
    var frames = 0, idle = 0
    func stream(_ stream: SCStream, didStopWithError error: Error) { print("I,error,\(error)"); exit(1) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let st = atts.first?[.status] as? Int, let status = SCFrameStatus(rawValue: st) else { return }
        guard status == .complete, let pb = CMSampleBufferGetImageBuffer(sb) else { idle += 1; return }
        var t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        if let dt = atts.first?[.displayTime] as? UInt64 { t = Double(dt) * Double(tb.numer) / Double(tb.denom) / 1e9 }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var hdr = Data(count: 24)
        hdr.withUnsafeMutableBytes { p in
            p.storeBytes(of: t, toByteOffset: 0, as: Double.self)
            p.storeBytes(of: Int32(w), toByteOffset: 8, as: Int32.self)
            p.storeBytes(of: Int32(h), toByteOffset: 12, as: Int32.self)
            p.storeBytes(of: Int32(w * 4), toByteOffset: 16, as: Int32.self)
        }
        var body = Data(capacity: w * h * 4)
        let base = CVPixelBufferGetBaseAddress(pb)!
        for y in 0..<h { body.append(base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self), count: w * 4) }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        out.write(hdr); out.write(body)
        frames += 1
    }
}
let sink = Sink()
var stream: SCStream?
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            print("I,error,no display"); exit(1)
        }
        let f = SCContentFilter(display: d, excludingWindows: [])
        let c = SCStreamConfiguration()
        c.sourceRect = CGRect(x: rx, y: ry, width: Double(rw), height: Double(rh))
        c.width = rw; c.height = rh
        c.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        c.showsCursor = true
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.queueDepth = 8
        let s = SCStream(filter: f, configuration: c, delegate: sink)
        try s.addStreamOutput(sink, type: .screen, sampleHandlerQueue: q)
        try await s.startCapture()
        stream = s
        print("I,start,\(CACurrentMediaTime()) display \(d.displayID) \(d.width)x\(d.height)")
        try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
        try await s.stopCapture()
        q.sync {}
        print("I,frames,\(sink.frames) idle \(sink.idle)")
        exit(0)
    } catch { print("I,error,\(error)"); exit(1) }
}
RunLoop.main.run()
