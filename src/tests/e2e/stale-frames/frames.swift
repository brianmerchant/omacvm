// frames: the Mac side of stale-frames.sh.
//   frames capture WINDOW-ID OUT.png   ScreenCaptureKit picture of one window, at its pixel
//                                      size, also when the window is on another Space
//   frames diff A B SKIP-TOP TOL       pixels that differ by more than TOL in a channel,
//                                      rows from SKIP-TOP down: "COUNT X0 Y0 X1 Y1" (bounding
//                                      box, or "0 - - - -"). A, B: a PNG, or
//                                      raw:WIDTH:HEIGHT:PITCH:FILE (XR24, as scanout-read writes)
import AppKit
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

struct Picture { var w = 0, h = 0; var px: [UInt8] = [] }   // RGBX rows, top first

func load(_ arg: String) -> Picture {
    var p = Picture()
    if arg.hasPrefix("raw:") {
        let f = arg.split(separator: ":", maxSplits: 4).map(String.init)
        guard f.count == 5, let w = Int(f[1]), let h = Int(f[2]), let pitch = Int(f[3]) else { fail("bad \(arg)") }
        guard let d = FileManager.default.contents(atPath: f[4]), d.count >= pitch * h else { fail("short \(f[4])") }
        p.w = w; p.h = h; p.px = [UInt8](repeating: 0, count: w * h * 4)
        d.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for y in 0..<h { for x in 0..<w {
                let s = y * pitch + x * 4, t = (y * w + x) * 4
                p.px[t] = b[s + 2]; p.px[t + 1] = b[s + 1]; p.px[t + 2] = b[s]   // B G R X -> R G B
            } }
        }
        return p
    }
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: arg) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(arg)") }
    p.w = img.width; p.h = img.height; p.px = [UInt8](repeating: 0, count: p.w * p.h * 4)
    let ctx = CGContext(data: &p.px, width: p.w, height: p.h, bitsPerComponent: 8, bytesPerRow: p.w * 4,
                        space: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: p.w, height: p.h))
    return p
}

let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "capture" where a.count == 4:
    _ = NSApplication.shared   // ScreenCaptureKit needs a connection to the window server
    guard let wid = UInt32(a[2]) else { fail("bad window id") }
    let done = DispatchSemaphore(value: 0)
    var err: String?
    Task {
        do {
            let c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let w = c.windows.first(where: { $0.windowID == wid }) else { err = "no window \(wid)"; done.signal(); return }
            let cfg = SCStreamConfiguration()
            let scale = NSScreen.screens.map { $0.backingScaleFactor }.max() ?? 2
            cfg.width = Int(w.frame.width * scale); cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w),
                                                                 configuration: cfg)
            let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(d, img, nil)
            if !CGImageDestinationFinalize(d) { err = "cannot write \(a[3])" }
        } catch { err = "\(error)" }
        done.signal()
    }
    done.wait()
    if let e = err { fail("frames capture: \(e)") }
case "diff" where a.count == 6:
    let p = load(a[2]), q = load(a[3])
    guard let top = Int(a[4]), let tol = Int(a[5]) else { fail("bad numbers") }
    guard p.w == q.w, p.h == q.h else { print("size \(p.w)x\(p.h) \(q.w)x\(q.h)"); exit(2) }
    var n = 0, x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
    for y in max(top, 0)..<p.h { for x in 0..<p.w {
        let i = (y * p.w + x) * 4
        if abs(Int(p.px[i]) - Int(q.px[i])) > tol || abs(Int(p.px[i + 1]) - Int(q.px[i + 1])) > tol ||
            abs(Int(p.px[i + 2]) - Int(q.px[i + 2])) > tol {
            n += 1; x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        }
    } }
    print(n == 0 ? "0 - - - -" : "\(n) \(x0) \(y0) \(x1) \(y1)")
default:
    fail("usage: frames capture WINDOW-ID OUT.png | frames diff A B SKIP-TOP TOL")
}
