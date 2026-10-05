// Tests of keylight.swift, built and run by src/tests/keyboard-light.sh.
//   keylight-test          the steps, the dark-step skip, the popup value (no hardware)
//   keylight-test live     this Mac's keyboard light: the dimmest step is kept and
//                          lit, then the level from before comes back
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  if ok { print("ok   \(what)") } else { failed += 1; print("FAIL \(what) (line \(line))") }
}
let s16: Float = 1.0 / 16

func offline() {
  typealias K = KeyboardSteps
  // Down from macOS's lowest through every low step to off, and back up.
  var v = s16, down: [Float] = []
  while v > 0 { v = K.next(v, up: false, low: true); down.append(v) }
  check(down == [0.04, 0.02, 0.01, 0.001, 0], "down from 1/16: 0.04 0.02 0.01 0.001 off (\(down))")
  var up: [Float] = []
  v = 0
  while v < s16 { v = K.next(v, up: true, low: true); up.append(v) }
  check(up == [0.001, 0.01, 0.02, 0.04, s16], "up from off: 0.001 0.01 0.02 0.04 1/16 (\(up))")
  check(K.low.first! > 0 && K.low.first! < 0.01, "the dimmest step is below the old 0.01 and above off")
  check(K.next(0, up: false, low: true) == 0, "off stays off going down")
  check(K.next(1, up: true, low: true) == 1, "full stays full going up")
  check(K.next(0.0625, up: true, low: true) == 2.0 / 16, "1/16 up = 2/16")
  // Without the low steps: macOS's own 16.
  check(K.next(s16, up: false, low: false) == 0, "low steps off: 1/16 down = off")
  check(K.next(0, up: true, low: false) == s16, "low steps off: off up = 1/16")
  // A value macOS reports a little off a step still moves one step.
  check(K.next(0.00099, up: true, low: true) == 0.01, "0.00099 up = 0.01")
  check(K.next(0.0011, up: false, low: true) == 0, "0.0011 down = off")
  check(K.next(0.03, up: false, low: true) == 0.02, "between steps (0.03) down = 0.02")

  // settle: a step the backlight reports dark is passed over, both ways.
  var sets: [Float] = []
  func run(_ from: Float, up: Bool, litFrom: Float) -> Float? {   // the keys light from litFrom on
    sets = []
    var now: Float = 0
    return K.settle(from: from, up: up, low: true, set: { now = $0; sets.append($0); return true }, lit: { now >= litFrom })
  }
  check(run(0, up: true, litFrom: 0) == 0.001, "every step lit: off up = 0.001")
  check(run(0, up: true, litFrom: 0.01) == 0.01 && sets == [0.001, 0.01], "0.001 dark here: off up = 0.01 (\(sets))")
  check(run(0.01, up: false, litFrom: 0.01) == 0 && sets == [0.001, 0], "0.001 dark here: 0.01 down = off (\(sets))")
  check(run(0, up: true, litFrom: 1) == s16, "all low steps dark: off up = 1/16, never on-but-dark")
  check(K.settle(from: 0, up: true, low: true, set: { _ in true }, lit: { nil }) == 0.001, "no level call: trust the step")
  check(K.settle(from: 0, up: true, low: true, set: { _ in false }, lit: { true }) == nil, "a failed set: nil")

  // Omarchy's popup: a lit keyboard never shows 0.
  check(K.osdPercent(0) == 0, "popup: off = 0")
  check(K.osdPercent(0.001) == 1, "popup: 0.001 = 1")
  check(K.osdPercent(0.04) == 4 && K.osdPercent(s16) == 6 && K.osdPercent(1) == 100, "popup: 4, 6, 100")
}

func live() {
  guard let start = KeyboardLight.get() else { print("skip: this Mac has no keyboard light"); return }
  defer {
    _ = KeyboardLight.set(start)
    usleep(300_000)
    check(abs((KeyboardLight.get() ?? -1) - start) < 0.0005, "back to the level from before (\(start))")
  }
  var levels: [Float: Float] = [:]
  for v in KeyboardSteps.low + [s16] {
    check(KeyboardLight.set(v), "set \(v)")
    usleep(300_000)
    let got = KeyboardLight.get() ?? -1, level = KeyboardLight.level()
    levels[v] = level ?? -1
    print(String(format: "     set %.4f: kept %.4f, backlight level %@", v, got, level.map { String(format: "%.4f", $0) } ?? "n/a"))
    check(abs(got - v) < 0.0002, "\(v) is kept")
  }
  if let dim = levels[KeyboardSteps.low[0]], let old = levels[0.01], dim >= 0 {
    check(dim > 0, "the dimmest step is lit (level \(dim))")
    check(dim < old, "the dimmest step is dimmer than 0.01 (\(dim) < \(old))")
  }
  // The key path: off, one press up, one press down.
  check(KeyboardLight.set(0), "set off")
  usleep(300_000)
  check(KeyboardLight.step(up: true, low: true) == KeyboardSteps.low[0], "off, one press up: the dimmest step")
  usleep(300_000)
  check(KeyboardLight.step(up: false, low: true) == 0, "one press down: off")
}

if CommandLine.arguments.dropFirst().first == "live" { live() } else { offline() }
if failed > 0 { print("\(failed) failed"); exit(1) }
print("all passed")
