// The Bridge's brightness-key reader (hid-keys.swift) with made-up keyboards
// in place of IOHIDManager: the real BrightnessKeys class gets key values as
// its IOKit callback hands them on. Then, read only, this Mac's own keyboards:
// their F-key maps through the same code (no key is pressed, nothing opened).
import Foundation
import IOKit.hid

func log(_ s: String) { print("log: \(s)") }

var failed = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
  print("\(ok ? "ok  " : "FAIL") \(what)")
  if !ok { failed += 1; print("     (line \(line))") }
}

let b = BrightnessKeys()
var got: [MediaKey] = []
b.onKey = { got.append($0) }
var reads: [UInt64: Int] = [:]
let macbook: [UInt32: UInt32] = [HIDUsage.f1: 0x00FF_0005, HIDUsage.f2: 0x00FF_0004, 0x0007_0044: 0x000C_00EA]
func key(_ dev: UInt64, _ page: UInt32, _ usage: UInt32, _ down: Bool, map: [UInt32: UInt32], fnState: Bool = false) {
  let u = HIDUsage.of(page: page, usage: usage)
  guard BrightnessKeys.wanted(u) else { return }   // as the IOKit callback filters
  b.input(device: dev, usage: u, pressed: down, fnState: fnState) { reads[dev, default: 0] += 1; return map }
}
func tap(_ dev: UInt64, _ page: UInt32, _ usage: UInt32, map: [UInt32: UInt32], fnState: Bool = false) {
  key(dev, page, usage, true, map: map, fnState: fnState); key(dev, page, usage, false, map: map, fnState: fnState)
}

// The MacBook's keyboard: F1, F2, F2, then a letter, F11 (volume) and Return.
tap(1, 7, 0x3A, map: macbook); tap(1, 7, 0x3B, map: macbook); tap(1, 7, 0x3B, map: macbook)
tap(1, 7, 0x04, map: macbook); tap(1, 7, 0x44, map: macbook); tap(1, 7, 0x28, map: macbook)
check(got == [.brightnessDown, .brightnessUp, .brightnessUp], "MacBook keyboard: F1, F2, F2 -> down, up, up; A, F11, Return: nothing")
check(reads[1] == 1, "... its map is read once")
check(!BrightnessKeys.wanted(HIDUsage.of(page: 7, usage: 0x04)) && !BrightnessKeys.wanted(HIDUsage.of(page: 7, usage: 0x28)),
      "letters and Return are never looked at")
// fn + F1 with the special keys on top: F1 (nothing for the Bridge).
got = []
key(1, 0xFF, 0x03, true, map: macbook); tap(1, 7, 0x3A, map: macbook); key(1, 0xFF, 0x03, false, map: macbook)
check(got.isEmpty, "fn + F1: plain F1")
// Magic Keyboard (USB/Bluetooth, no map: Apple's default), standard F-keys on.
got = []
tap(2, 7, 0x3B, map: HIDBrightness.appleDefault, fnState: true)
key(2, 0xFF01, 0x03, true, map: HIDBrightness.appleDefault, fnState: true)
tap(2, 7, 0x3B, map: HIDBrightness.appleDefault, fnState: true)
key(2, 0xFF01, 0x03, false, map: HIDBrightness.appleDefault, fnState: true)
check(got == [.brightnessUp], "Magic Keyboard, standard F-keys: F2 is F2, fn + F2 is brightness up")
// The Mac mini's Magic Keyboard: Bluetooth, vendor 0x004C, no FnFunctionUsageMap (read on the mini with ioreg).
got = []
let btMap = HIDBrightness.map(published: nil, vendor: 0x004C)
tap(4, 7, 0x3A, map: btMap); tap(4, 7, 0x3B, map: btMap); tap(4, 7, 0x3B, map: btMap)
check(got == [.brightnessDown, .brightnessUp, .brightnessUp], "Bluetooth Magic Keyboard (0x004C, no map): F1, F2, F2 -> down, up, up")
got = []
key(4, 0xFF, 0x03, true, map: btMap); tap(4, 7, 0x3A, map: btMap); key(4, 0xFF, 0x03, false, map: btMap)
tap(4, 0x0C, 0x6F, map: btMap)
check(got == [.brightnessUp], "... fn + F1 is F1; its consumer brightness up still acts")
got = []
tap(4, 7, 0x3A, map: btMap, fnState: true)
key(4, 0xFF, 0x03, true, map: btMap, fnState: true); tap(4, 7, 0x3A, map: btMap, fnState: true); key(4, 0xFF, 0x03, false, map: btMap, fnState: true)
check(got == [.brightnessDown], "... standard F-keys on: F1 is F1, fn + F1 is brightness down")
// A PC keyboard's own brightness keys (consumer page).
got = []
tap(3, 0x0C, 0x70, map: [:]); tap(3, 0x0C, 0x6F, map: [:]); tap(3, 7, 0x3A, map: [:])
check(got == [.brightnessDown, .brightnessUp], "PC keyboard: its brightness keys act, its F1 is F1")

// ---- this Mac's keyboards, read only ----
let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
let devices = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
if devices.isEmpty { print("skip this Mac: no keyboard (CI)") }
for d in devices {
  let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
  let map = BrightnessKeys.fnMap(d, IOHIDDeviceGetService(d))
  let f1 = map[HIDUsage.f1].flatMap(HIDBrightness.key), f2 = map[HIDUsage.f2].flatMap(HIDBrightness.key)
  print("this Mac: \(name): F1 -> \(f1.map { "\($0)" } ?? "-"), F2 -> \(f2.map { "\($0)" } ?? "-") (\(map.count) keys mapped)")
  if !map.isEmpty { check(f1 == .brightnessDown && f2 == .brightnessUp, "this Mac: \(name): F1/F2 are its brightness keys") }
}
print("standard function keys (fnState): \(BrightnessKeys.fnState())")
if failed > 0 { print("\(failed) failed"); exit(1) }
print("hid keys: all ok")
