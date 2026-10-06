// Touch ID panel (ADR 0041, addendum 3.0.2), the parts without AppKit: the
// words, where the panel goes, which keys cancel, when macOS's own alert is
// used instead, and that a panel ends once. touchid_panel.swift draws it;
// tests/touchid runs this file as is.
import CoreGraphics
import Foundation

/// What the panel says. Only from the request the Bridge verified, cleaned
/// as for touchIDReason: the box holds exactly what the alert would show.
struct TouchIDPanelText: Equatable {
  var title: String   // "Touch ID in Omarchy", " (VM)" with several VMs
  var line: String    // who asks, plain
  var box: String?    // the command or polkit action, mono, whole
}

func touchIDPanelText(_ r: TouchIDRequest, vm: String?) -> TouchIDPanelText {
  let title = "Touch ID in Omarchy" + (vm.map { " (\(touchIDClean($0, max: 40)))" } ?? "")
  switch r.kind {
  case .onePassword: return TouchIDPanelText(title: title, line: "Unlock 1Password", box: nil)
  case .sudo:
    let at = r.tty.isEmpty ? "" : " in \(r.tty)"
    let cmd = touchIDClean(r.detail, max: touchIDCommandMax)
    return cmd.isEmpty ? TouchIDPanelText(title: title, line: "Run sudo\(at)", box: nil)
                       : TouchIDPanelText(title: title, line: "sudo\(at) wants to run", box: cmd)
  case .polkit:
    return TouchIDPanelText(title: title, line: "Allow a system request", box: r.action.isEmpty ? nil : r.action)
  }
}

// ---- placement ----

enum TouchIDPanelStyle: Equatable { case window, notch }

/// A screen as the panel needs it, in Cocoa coordinates (origin bottom left
/// of the main screen). `notchMidX`: the camera housing's middle, nil
/// without a notch; `safeTop`: the strip's height above the safe area.
struct TouchIDPanelScreen: Equatable {
  var frame: CGRect
  var visible: CGRect
  var safeTop: CGFloat = 0
  var notchMidX: CGFloat?
}

struct TouchIDPanelPlacement: Equatable {
  var style: TouchIDPanelStyle
  var frame: CGRect
  var screen: Int
}

/// CGWindowList's bounds (origin top left of the main screen) -> Cocoa's.
func touchIDCocoaRect(_ cg: CGRect, mainHeight: CGFloat) -> CGRect {
  CGRect(x: cg.minX, y: mainHeight - cg.maxY, width: cg.width, height: cg.height)
}

/// The smallest VM window the panel goes over; smaller ones are not the VM's screen.
let touchIDPanelMinWindow = CGSize(width: 200, height: 150)

/// Where the panel goes for the VM's window (Cocoa coordinates), or nil
/// (macOS's alert then). `size(style)` is the panel's size in that style.
/// Windowed: centred on the window, its top 22 % down the window (at most
/// 180 pt), inside the screen's visible frame. Full screen on a screen with
/// a notch: a card hanging from the strip, centred on the notch.
func touchIDPanelPlacement(window w: CGRect, screens: [TouchIDPanelScreen],
                           size: (TouchIDPanelStyle) -> CGSize) -> TouchIDPanelPlacement? {
  guard w.width >= touchIDPanelMinWindow.width, w.height >= touchIDPanelMinWindow.height else { return nil }
  var best: (i: Int, area: CGFloat)?
  for (i, s) in screens.enumerated() {
    let o = s.frame.intersection(w)
    let a = o.isNull ? 0 : o.width * o.height
    if a > 0, a > (best?.area ?? 0) { best = (i, a) }
  }
  guard let i = best?.i else { return nil }
  let s = screens[i]
  // Full screen: as wide as the screen, from its bottom up to the strip (or over it).
  let full = abs(w.width - s.frame.width) <= 2 && abs(w.minX - s.frame.minX) <= 2 && abs(w.minY - s.frame.minY) <= 2
    && w.maxY >= s.frame.maxY - s.safeTop - 2
  if full, s.safeTop > 0, let mid = s.notchMidX {
    let z = size(.notch)
    var x = (mid - z.width / 2).rounded()
    x = min(max(x, s.frame.minX), s.frame.maxX - z.width)
    return TouchIDPanelPlacement(style: .notch, frame: CGRect(x: x, y: s.frame.maxY - s.safeTop - z.height,
                                                              width: z.width, height: z.height), screen: i)
  }
  let z = size(.window)
  let v = s.visible
  var x = (w.midX - z.width / 2).rounded()
  var top = w.maxY - min(w.height * 0.22, 180)
  x = min(max(x, v.minX), v.maxX - z.width)
  top = min(max(top, v.minY + z.height), v.maxY)
  return TouchIDPanelPlacement(style: .window, frame: CGRect(x: x, y: (top - z.height).rounded(),
                                                             width: z.width, height: z.height), screen: i)
}

// ---- keys ----

enum TouchIDPanelKey: Equatable { case cancel, ignore }

/// Esc and Cmd-. cancel; nothing else does anything (Return least of all:
/// there is no default button, only a finger says yes). Events that carry
/// OmacVM's own marker (Gestures' hotkeys, the Bridge's reposted keys) are
/// ignored: a VM can cause those.
func touchIDPanelKey(keyCode: UInt16, command: Bool, marked: Bool) -> TouchIDPanelKey {
  if marked { return .ignore }
  if keyCode == 53 { return .cancel }                 // Esc
  if keyCode == 47 && command { return .cancel }      // Cmd-.
  return .ignore
}

// ---- panel or macOS's alert ----

/// Which of the two shows a request. The panel only when the password is
/// not offered (the Mac password needs the alert), the setting is not off,
/// the VM's window was found, and the embedded view has not failed in this
/// Bridge run.
enum TouchIDShow: Equatable { case panel, alert }

/// How an evaluation ended, as far as the gate cares.
enum TouchIDLAEnd: Equatable { case yes, cancelled, lockout, notAvailable, failed, other }

/// The embedded view failed fast once: macOS's alert for the rest of the run.
struct TouchIDPanelGate {
  private(set) var broken = false
  static let fast: TimeInterval = 0.5

  func show(passwordFallback: Bool, setting: Bool, windowFound: Bool) -> TouchIDShow {
    passwordFallback || !setting || !windowFound || broken ? .alert : .panel
  }

  /// After the panel's evaluation: true when it could not have shown (an
  /// error other than a cancel, lockout, "not available" or a wrong finger
  /// within 0.5 s). Then this request goes to the alert, and every later one.
  mutating func ended(_ e: TouchIDLAEnd, after: TimeInterval) -> Bool {
    guard e == .other, after < TouchIDPanelGate.fast else { return false }
    broken = true
    return true
  }
}

// ---- one panel, one end ----

/// The first end wins; anything later (a Cancel click after the timeout,
/// the reply after an invalidate) changes nothing.
struct TouchIDPanelState {
  private(set) var end: TouchIDOutcome?
  @discardableResult
  mutating func finish(_ o: TouchIDOutcome) -> Bool {
    guard end == nil else { return false }
    end = o
    return true
  }
}

/// An evaluation's own end -> the answer (fast errors aside: the caller's gate).
func touchIDOutcome(_ e: TouchIDLAEnd) -> TouchIDOutcome {
  switch e {
  case .yes: return .yes
  case .cancelled: return .no(.cancelled)
  case .lockout: return .no(.lockout)
  case .notAvailable: return .no(.noTouchID)
  case .failed, .other: return .no(.failed)
  }
}
