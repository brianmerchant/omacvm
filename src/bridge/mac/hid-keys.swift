// Brightness keys read from the keyboard itself (why: keys-model.swift,
// HIDKeyboards). keys.swift's MediaKeys acts on them.
import AppKit   // NSEvent: macOS's key repeat speed
import IOKit
import IOKit.hid

// ---- brightness keys from the keyboard (HIDKeyboards: keys-model.swift) ----
// IOHIDManager on every keyboard, never seized (macOS keeps every key); needs
// Input Monitoring. Only F1-F12, fn and the brightness usages are looked at,
// nothing is kept or logged. Main thread (main run loop).
final class BrightnessKeys {
  private var manager: IOHIDManager?
  private var keyboards = HIDKeyboards()
  private var maps: [UInt64: [UInt32: UInt32]] = [:]   // per keyboard (registry id)
  private var said: String?
  private var asked = false
  var onKey: ((MediaKey) -> Void)?

  // A held key repeats at macOS's key repeat speed (Keyboard settings): HID
  // sends one press and one release, no repeats. Stops on release, on another
  // brightness press, or after `maxRepeats` (a release that never came).
  static let maxRepeats = 64
  private var held: (device: UInt64, usage: UInt32, key: MediaKey)?
  private var holdID = 0
  var repeatTimes: () -> (delay: Double, interval: Double) = { (NSEvent.keyRepeatDelay, NSEvent.keyRepeatInterval) }
  var after: (Double, @escaping () -> Void) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1) }

  /// Opens once Input Monitoring is granted (asked every 2 s with the media
  /// keys); not decided yet: macOS asks the user once. What is missing is
  /// logged once.
  func ensure() {
    guard manager == nil else { return }
    let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    if access == kIOHIDAccessTypeUnknown && !asked {
      asked = true
      _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
    guard access == kIOHIDAccessTypeGranted else {
      say("brightness keys: Input Monitoring for OmacVM Bridge is \(access == kIOHIDAccessTypeDenied ? "off" : "not decided yet"): "
          + "with a VM in front they do nothing (System Settings > Privacy & Security > Input Monitoring)")
      return
    }
    let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let kinds: [[String: Any]] = [[kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
                                  [kIOHIDDeviceUsagePageKey: kHIDPage_Consumer, kIOHIDDeviceUsageKey: kHIDUsage_Csmr_ConsumerControl]]
    IOHIDManagerSetDeviceMatchingMultiple(m, kinds as CFArray)
    IOHIDManagerRegisterInputValueCallback(m, { ctx, _, _, value in
      guard let ctx else { return }
      Unmanaged<BrightnessKeys>.fromOpaque(ctx).takeUnretainedValue().value(value)
    }, Unmanaged.passUnretained(self).toOpaque())
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
    guard r == kIOReturnSuccess else {
      IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
      say("brightness keys: cannot read the keyboard (IOHIDManagerOpen: 0x\(String(UInt32(bitPattern: r), radix: 16))); retrying")
      return
    }
    manager = m
    said = nil
    log("brightness keys: reading them from the keyboard (they act only while an OmacVM VM is in front)")
  }

  private func say(_ s: String) {
    guard s != said else { return }
    said = s
    log(s)
  }

  private func value(_ v: IOHIDValue) {
    let e = IOHIDValueGetElement(v)
    let usage = HIDUsage.of(page: IOHIDElementGetUsagePage(e), usage: IOHIDElementGetUsage(e))
    guard Self.wanted(usage) else { return }
    let device = IOHIDElementGetDevice(e)
    let service = IOHIDDeviceGetService(device)
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &id)
    input(device: id, usage: usage, pressed: IOHIDValueGetIntegerValue(v) != 0, fnState: Self.fnState()) {
      Self.fnMap(device, service)
    }
  }

  /// Only these usages are looked at: F1-F12, fn, the brightness usages.
  static func wanted(_ usage: UInt32) -> Bool {
    HIDUsage.fn.contains(usage) || HIDBrightness.key(usage) != nil || (0x0007_003A...0x0007_0045).contains(usage)
  }

  /// One key value of one keyboard (test-hid.sh drives this with made-up
  /// keyboards); its map is read once per keyboard.
  func input(device id: UInt64, usage: UInt32, pressed: Bool, fnState: Bool, map read: () -> [UInt32: UInt32]) {
    let map = maps[id] ?? {
      let m = read()
      maps[id] = m
      return m
    }()
    if !pressed, let h = held, h.device == id, h.usage == usage { held = nil }
    guard let key = keyboards.value(device: id, usage: usage, pressed: pressed, map: map, fnState: fnState) else { return }
    onKey?(key)
    holdID += 1
    held = (id, usage, key)
    let hold = holdID
    after(max(0.05, repeatTimes().delay)) { [weak self] in self?.repeatKey(hold, 0) }
  }

  private func repeatKey(_ hold: Int, _ n: Int) {
    guard hold == holdID, let h = held, n < Self.maxRepeats else { return }
    onKey?(h.key)
    after(max(0.015, repeatTimes().interval)) { [weak self] in self?.repeatKey(hold, n + 1) }
  }

  /// The keyboard's own F-key map (on its event driver, below the device);
  /// an Apple keyboard (USB or Bluetooth) without one: F1/F2 as on all of them.
  static func fnMap(_ device: IOHIDDevice, _ service: io_service_t) -> [UInt32: UInt32] {
    let s = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "FnFunctionUsageMap" as CFString, nil,
                                            IOOptionBits(kIORegistryIterateRecursively)) as? String
    return HIDBrightness.map(published: s, vendor: IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int)
  }

  /// "Use F1, F2, etc. keys as standard function keys" (Keyboard settings).
  static func fnState() -> Bool {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
    return CFPreferencesCopyAppValue("com.apple.keyboard.fnState" as CFString, kCFPreferencesAnyApplication) as? Bool ?? false
  }
}
