// POST /wallpaper: the VM's current Omarchy background becomes the Mac's
// wallpaper on every display and every Space, which macOS also shows behind its
// lock screen. The guest sends it whenever the theme or background changes.
import AppKit
import CryptoKit

let wallpaperDir = supportDir + "/wallpaper"

func setWallpaper(_ data: Data, theme: String) throws -> String {
  guard !data.isEmpty, NSImage(data: data) != nil else { throw APIError(400, "the body must be an image (PNG or JPEG)") }
  let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
  let ext = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "jpg"
  let file = "\(wallpaperDir)/background-\(hash).\(ext)"
  let fm = FileManager.default
  try fm.createDirectory(atPath: wallpaperDir, withIntermediateDirectories: true)
  if !fm.fileExists(atPath: file) {
    try data.write(to: URL(fileURLWithPath: file), options: .atomic)
  }
  // Keep only the current picture (macOS reads it again after a restart).
  for f in (try? fm.contentsOfDirectory(atPath: wallpaperDir)) ?? [] where f.hasPrefix("background-") && "\(wallpaperDir)/\(f)" != file {
    try? fm.removeItem(atPath: "\(wallpaperDir)/\(f)")
  }
  // The test identity's Bridge (control.swift) never changes the Mac's own
  // wallpaper: test VMs post theirs on every apply and theme change.
  if testIdentity {
    return "wallpaper \(theme.isEmpty ? "" : theme + " ")(\(data.count / 1024) KB), kept: the test identity leaves the Mac's wallpaper as it is"
  }
  var failures: [String] = []
  DispatchQueue.main.sync {
    let opts: [NSWorkspace.DesktopImageOptionKey: Any] = [
      .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
    for screen in NSScreen.screens {
      do { try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: file), for: screen, options: opts) }
      catch { failures.append("\(screen.localizedName): \(error.localizedDescription)") }
    }
  }
  guard failures.isEmpty else { throw APIError(500, "setting the wallpaper failed: " + failures.joined(separator: "; ")) }
  setOnAllSpaces(URL(fileURLWithPath: file))
  return "wallpaper \(theme.isEmpty ? "" : theme + " ")(\(data.count / 1024) KB)"
}

// macOS keeps a wallpaper per Space, and NSWorkspace only sets the Space that is
// active on each screen: when the theme changes in a full-screen VM, that is the
// VM's own Space, and the desktop Spaces keep the old picture (whose file is
// gone). So the picture also goes into WallpaperAgent's store for every Space,
// every display and new Spaces, and WallpaperAgent restarts to read it
// (macOS 14+; macOS 13 keeps NSWorkspace's result).
let wallpaperStore = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
let imageProvider = "com.apple.wallpaper.choice.image"

func setOnAllSpaces(_ url: URL) {
  Thread.sleep(forTimeInterval: 0.5)   // WallpaperAgent first saves the Space NSWorkspace just set
  guard let data = try? Data(contentsOf: wallpaperStore),
        var store = try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil) as? [String: Any]
  else { return }
  // The just-set Space's picture settings (placement, background colour) for every Space.
  var config: Any?
  func findConfig(_ o: Any) {
    if let d = o as? [String: Any] {
      if d["Provider"] as? String == imageProvider, let c = d["Configuration"] { config = c; return }
      d.values.forEach { if config == nil { findConfig($0) } }
    } else if let a = o as? [Any] { a.forEach { if config == nil { findConfig($0) } } }
  }
  findConfig(store)
  var changed = 0
  func rewrite(_ o: Any) -> Any {
    if var d = o as? [String: Any] {
      for (k, v) in d {
        if k == "Desktop", var desktop = v as? [String: Any], var content = desktop["Content"] as? [String: Any] {
          var choice: [String: Any] = ["Provider": imageProvider, "Files": [["relative": url.absoluteString]]]
          if let c = config { choice["Configuration"] = c }
          else if let old = (content["Choices"] as? [[String: Any]])?.first, old["Provider"] as? String == imageProvider {
            choice = old; choice["Files"] = [["relative": url.absoluteString]]
          } else { continue }
          content["Choices"] = [choice]; content["Shuffle"] = "$null"
          desktop["Content"] = content; d[k] = desktop; changed += 1
        } else { d[k] = rewrite(v) }
      }
      return d
    }
    if let a = o as? [Any] { return a.map(rewrite) }
    return o
  }
  store = rewrite(store) as! [String: Any]
  guard changed > 0,
        let out = try? PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0),
        (try? out.write(to: wallpaperStore, options: .atomic)) != nil
  else { log("wallpaper: could not update every Space"); return }
  let restart = Process()
  restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
  restart.arguments = ["WallpaperAgent"]
  try? restart.run(); restart.waitUntilExit()
}
