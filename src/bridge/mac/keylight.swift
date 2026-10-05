// The Mac's keyboard light: its levels (KeyboardSteps, plain logic, tested by
// src/tests/keyboard-light.sh) and macOS's private client for it (KeyboardLight).
// Foundation only, so the test builds it without the rest of the Bridge.
import Foundation

enum KeyboardSteps {
  /// Below macOS's lowest step (1/16), dimmest first. Measured on a MacBook Pro
  /// M4 Max (macOS 15.7): every value is kept and the backlight reports its own
  /// level for it (backlightLevelForKeyboard: 0.115, 0.25, 0.39, 0.68 against
  /// 1.01 at 1/16). Any value above 0 gives at least 0.10 there, so 0.001 is
  /// about as dim as the keys go while still lit.
  static let low: [Float] = [0.001, 0.01, 0.02, 0.04]
  static let macOSLowest: Float = 1.0 / 16

  /// The next level up or down: 0 (off), the low steps, then macOS's 16 steps.
  static func next(_ v: Float, up: Bool, low useLow: Bool) -> Float {
    let levels = [0] + (useLow ? low : []) + (1...16).map { Float($0) / 16 }
    let near: Float = 0.0004   // under half the smallest gap (0 to 0.001)
    return up ? levels.first { $0 > v + near } ?? 1 : levels.last { $0 < v - near } ?? 0
  }

  /// Steps with `set` until the keys are lit or off: a low step the backlight
  /// reports as dark (`lit` false: another Mac's hardware may not go that low)
  /// is passed over, so no key press ends on "on but dark". nil: a set failed.
  static func settle(from v: Float, up: Bool, low useLow: Bool,
                     set: (Float) -> Bool, lit: () -> Bool?) -> Float? {
    var to = next(v, up: up, low: useLow)
    while true {
      guard set(to) else { return nil }
      if to == 0 || to >= macOSLowest || lit() != false { return to }
      to = next(to, up: up, low: useLow)
    }
  }

  /// 0-100 for Omarchy's popup: a lit keyboard shows at least 1, never 0.
  static func osdPercent(_ v: Float) -> Int {
    v > 0 ? max(1, Int((Double(v) * 100).rounded())) : 0
  }
}

// ---- keyboard backlight (CoreBrightness KeyboardBrightnessClient, private) ----
enum KeyboardLight {
  private typealias Get = @convention(c) (AnyObject, Selector, UInt64) -> Float
  private typealias Set = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
  private typealias IsBuiltIn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
  private static let getSel = NSSelectorFromString("brightnessForKeyboard:")
  private static let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
  private static let levelSel = NSSelectorFromString("backlightLevelForKeyboard:")
  private static let client: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
          let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
    let c = cls.init()
    return c.responds(to: getSel) && c.responds(to: setSel) ? c : nil
  }()
  private static let keyboard: UInt64? = {
    guard let c = client,
          let ids = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber] else { return nil }
    let sel = NSSelectorFromString("isKeyboardBuiltIn:")
    let builtIn = c.responds(to: sel) ? unsafeBitCast(c.method(for: sel), to: IsBuiltIn.self) : nil
    return (ids.first { builtIn?(c, sel, $0.uint64Value) ?? true } ?? ids.first)?.uint64Value
  }()
  private static var lastOn: Float = 0.5   // for the toggle key
  private static var levelSeen = false     // the level call answered above 0 once: it means something here

  static func get() -> Float? {
    guard let c = client, let k = keyboard else { return nil }
    let v = unsafeBitCast(c.method(for: getSel), to: Get.self)(c, getSel, k)
    return v < 0 ? nil : v
  }

  static func set(_ v: Float) -> Bool {
    guard let c = client, let k = keyboard else { return false }
    if let now = get(), now > 0, level() != 0 { lastOn = now }   // a lit level, for the toggle
    return unsafeBitCast(c.method(for: setSel), to: Set.self)(c, setSel, max(0, min(1, v)), k)
  }

  /// The level the backlight reports for what was set (it answers at once);
  /// nil when this macOS has no such call.
  static func level() -> Float? {
    guard let c = client, let k = keyboard, c.responds(to: levelSel) else { return nil }
    let l = unsafeBitCast(c.method(for: levelSel), to: Get.self)(c, levelSel, k)
    if l > 0 { levelSeen = true }
    return l
  }

  /// Lit or not by the level call; nil (trust the step) until it ever said
  /// more than 0, so a macOS where it always answers 0 keeps every step.
  private static func lit() -> Bool? {
    guard let l = level() else { return nil }
    return l > 0 ? true : levelSeen ? false : nil
  }

  /// One key press: the next lit level (see KeyboardSteps.settle).
  static func step(up: Bool, low: Bool) -> Float? {
    guard let v = get() else { return nil }
    return KeyboardSteps.settle(from: v, up: up, low: low, set: set, lit: lit)
  }

  static func toggle() -> Bool { guard let now = get() else { return false }; return set(now > 0 ? 0 : lastOn) }
}
