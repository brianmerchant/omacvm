// Touch ID for the VM (ADR 0041), the parts without macOS: the request, the
// dialog text, the limits and the order of the checks. touchid.swift adds
// LocalAuthentication and the Mac's state; tests/touchid mocks both.
import Foundation

let touchIDPath = "/omacvm/touchid"
let touchIDBodyMax = 1024
let touchIDRequestLabel = "omacvm-touchid-request 1"
let touchIDAnswerLabel = "omacvm-touchid-answer 1"
let touchIDDialogTimeout: Double = 30

/// The file name of a VM's Touch ID key on the Mac: the control key's name + ".touchid".
func touchIDKeyName(type: String, name: String) -> String { vmKeyName(type: type, name: name) + ".touchid" }

enum TouchIDKind: String { case sudo, polkit, onePassword = "1password" }

struct TouchIDRequest: Equatable {
  let kind: TouchIDKind
  let user: String
  let detail: String
  let action: String
}

/// Why the answer is no. The VM shows the fast ones (TouchIDNo.fast).
enum TouchIDNo: String {
  case cancelled, failed, timeout, busy, rate, locked, notFront = "not-front", noTouchID = "no-touch-id", lockout, off
}

private func matches(_ s: String, first: (UInt8) -> Bool, rest: (UInt8) -> Bool, max: Int) -> Bool {
  let b = Array(s.utf8)
  guard let f = b.first, b.count <= max, first(f) else { return false }
  return b.dropFirst().allSatisfy(rest)
}
private func lower(_ c: UInt8) -> Bool { (97...122).contains(c) }
private func digit(_ c: UInt8) -> Bool { (48...57).contains(c) }

/// Strict JSON, at most 1 KB, known keys only, each field checked.
func parseTouchIDRequest(_ body: Data) -> Result<TouchIDRequest, PolicyError> {
  guard body.count <= touchIDBodyMax else { return .failure(PolicyError(413, "too-large", "body over \(touchIDBodyMax) bytes")) }
  let o: [String: Any]
  do {
    guard let obj = try strictObject(body, allowed: ["kind", "user", "detail", "action"]) else {
      return .failure(PolicyError(400, "bad-json", "body must be a JSON object"))
    }
    o = obj
  } catch let e as PolicyError { return .failure(e) } catch { return .failure(PolicyError(400, "bad-json", "body must be a JSON object")) }
  func text(_ k: String) -> String?? {   // nil: wrong type; .some(nil): missing
    guard let v = o[k] else { return .some(nil) }
    guard let s = v as? String else { return nil }
    return .some(s)
  }
  guard let k = text("kind"), let ks = k, let kind = TouchIDKind(rawValue: ks) else {
    return .failure(PolicyError(400, "kind", "kind: sudo, polkit or 1password"))
  }
  guard let u = text("user"), let user = u,
        matches(user, first: { lower($0) || $0 == 95 }, rest: { lower($0) || digit($0) || $0 == 95 || $0 == 45 }, max: 32) else {
    return .failure(PolicyError(400, "user", "user: a Linux user name"))
  }
  guard let d = text("detail") else { return .failure(PolicyError(400, "detail", "detail: text")) }
  let detail = d ?? ""
  guard detail.utf8.count <= 200 else { return .failure(PolicyError(400, "detail", "detail: at most 200 bytes")) }
  guard let a = text("action") else { return .failure(PolicyError(400, "action", "action: a polkit action id")) }
  let action = a ?? ""
  let actionChar: (UInt8) -> Bool = { lower($0) || (65...90).contains($0) || digit($0) || $0 == 46 || $0 == 95 || $0 == 45 }
  guard action.isEmpty || matches(action, first: actionChar, rest: actionChar, max: 128) else {
    return .failure(PolicyError(400, "action", "action: a polkit action id"))
  }
  return .success(TouchIDRequest(kind: kind, user: user, detail: detail, action: action))
}

/// Text from the VM for the dialog: no control or direction characters, cut to `max`.
func touchIDClean(_ s: String, max: Int) -> String {
  let bad: (Unicode.Scalar) -> Bool = { c in
    let v = c.value
    return v < 0x20 || (0x7f...0x9f).contains(v) || v == 0x061c || v == 0x200e || v == 0x200f
      || (0x202a...0x202e).contains(v) || (0x2066...0x2069).contains(v) || v == 0x2028 || v == 0x2029 || v == 0xfeff
  }
  var out = String(String.UnicodeScalarView(s.unicodeScalars.map { bad($0) ? Unicode.Scalar(UInt8(32)) : $0 }))
  out = out.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
  if out.count > max { out = String(out.prefix(max - 1)) + "…" }
  return out
}

/// macOS shows "OmacVM Bridge is trying to <reason>." `vm`: the VM's name when
/// this Mac has more than one VM set up, else nil.
func touchIDReason(_ r: TouchIDRequest, vm: String?) -> String {
  let place = "Omarchy" + (vm.map { " (\(touchIDClean($0, max: 40)))" } ?? "")
  switch r.kind {
  case .onePassword: return "unlock 1Password in \(place)"
  case .sudo:
    let cmd = touchIDClean(r.detail, max: 80)
    return cmd.isEmpty ? "run sudo in \(place)" : "run sudo in \(place): \(cmd)"
  case .polkit:
    return r.action.isEmpty ? "allow a system request in \(place)" : "allow \"\(r.action)\" in \(place)"
  }
}

/// The VM app type (omacvm vms --json "type") of the app in front, from its executable.
func vmTypeOfExecutable(_ path: String) -> String? {
  let name = (path as NSString).lastPathComponent
  if path.hasSuffix("/runtime/bin/OmacVM") || name == "qemu-system-aarch64" { return "app" }
  switch name {
  case "prl_client_app": return "parallels"
  case "UTM": return "utm"
  case "VMware Fusion": return "fusion"
  default: return nil
  }
}

/// One dialog at a time on the Mac; per VM one request every 2 s, 10 a
/// minute, and 60 s of "rate" after 3 cancelled or failed in a row.
struct TouchIDLimiter {
  private(set) var busy = false
  private var last: [String: Date] = [:]
  private var minute: [String: [Date]] = [:]
  private var failures: [String: Int] = [:]
  private var pausedUntil: [String: Date] = [:]

  mutating func admit(_ vm: String, now: Date) -> TouchIDNo? {
    if let p = pausedUntil[vm], now < p { return .rate }
    if let l = last[vm], now.timeIntervalSince(l) < 2 { return .rate }
    let recent = (minute[vm] ?? []).filter { now.timeIntervalSince($0) < 60 }
    minute[vm] = recent
    if recent.count >= 10 { return .rate }
    if busy { return .busy }
    busy = true
    last[vm] = now
    minute[vm] = recent + [now]
    return nil
  }

  /// After an admitted request: the dialog is closed, and the count of misses goes on.
  mutating func finished(_ vm: String, yes: Bool, no: TouchIDNo?, now: Date) {
    busy = false
    if yes { failures[vm] = 0; return }
    guard no == .cancelled || no == .failed else { return }
    let n = (failures[vm] ?? 0) + 1
    if n >= 3 { pausedUntil[vm] = now.addingTimeInterval(60); failures[vm] = 0 } else { failures[vm] = n }
  }
}

enum TouchIDOutcome: Equatable { case yes, no(TouchIDNo) }

/// LocalAuthentication, or a mock.
protocol TouchIDAuthenticator {
  /// Nil when a dialog can be shown; else why not (no-touch-id, lockout).
  func unavailable(passwordFallback: Bool) -> TouchIDNo?
  /// Shows the dialog; a fresh context each time. `gone` is asked about every
  /// quarter second: true (the VM's client went away) cancels the dialog.
  func evaluate(reason: String, passwordFallback: Bool, timeout: Double, gone: @escaping () -> Bool) -> TouchIDOutcome
}

/// The Mac's state, or a mock.
protocol TouchIDMacState {
  var locked: Bool { get }          // screen locked or display asleep
  var frontType: String? { get }    // the VM app type in front (vmTypeOfExecutable), nil for another app
}

/// The checks in order, and the dialog. Thread-safe: requests come on their own threads.
final class TouchIDDecider {
  private let lock = NSLock()
  private var limits = TouchIDLimiter()
  let auth: TouchIDAuthenticator
  let mac: TouchIDMacState
  var timeout = touchIDDialogTimeout
  init(auth: TouchIDAuthenticator, mac: TouchIDMacState) { self.auth = auth; self.mac = mac }

  /// `vm`: the VM's key for the limits; `type`: its app (omacvm vms --json);
  /// `on`: the feature is on for it (its key is on the Mac).
  func decide(vm: String, type: String, on: Bool, request: TouchIDRequest, vmLabel: String?, passwordFallback: Bool,
              now: Date = Date(), gone: @escaping () -> Bool = { false }) -> TouchIDOutcome {
    guard on else { return .no(.off) }
    if let n = locked({ limits.admit(vm, now: now) }) { return .no(n) }
    let outcome: TouchIDOutcome
    if mac.locked { outcome = .no(.locked) }
    else if mac.frontType != type { outcome = .no(.notFront) }
    else if let n = auth.unavailable(passwordFallback: passwordFallback) { outcome = .no(n) }
    else { outcome = auth.evaluate(reason: touchIDReason(request, vm: vmLabel), passwordFallback: passwordFallback, timeout: timeout, gone: gone) }
    // The pause after misses counts from the request's time (tests give it).
    locked {
      if case .no(let n) = outcome { limits.finished(vm, yes: false, no: n, now: now) } else { limits.finished(vm, yes: true, no: nil, now: now) }
    }
    return outcome
  }

  private func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }
}

/// The answer's body: {"result":"yes"} or {"result":"no","reason":...}.
func touchIDAnswer(_ o: TouchIDOutcome) -> [String: Any] {
  switch o {
  case .yes: return ["result": "yes"]
  case .no(let n): return ["result": "no", "reason": n.rawValue]
  }
}
