// The app's window for src/tests/e2e/cc-switches.sh, through Accessibility,
// on one process only (its pid: STANDARDS 47, never "the app named ..."):
//   ax PID dump            every element: role, title, description, value
//   ax PID text            the window's words (static texts and values), one line each
//   ax PID press LABEL     presses the control named LABEL (its title, description or
//                          identifier; else the first control after a text LABEL,
//                          as a SwiftUI row with a label and a button)
//   ax PID has LABEL       exit 0 when such a control exists and is enabled
// Exit 0 done, 1 not found / refused, 2 usage, 3 no Accessibility for this process.
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
  var v: AnyObject?
  return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String {
  guard let v = attr(e, name) else { return "" }
  if let s = v as? String { return s }
  if let n = v as? NSNumber { return n.stringValue }
  return ""
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

struct Node { let e: AXUIElement; let role, title, desc, value, ident: String; let enabled: Bool }

func walk(_ e: AXUIElement, _ out: inout [Node], depth: Int = 0) {
  guard depth < 60, out.count < 5000 else { return }
  let en = (attr(e, kAXEnabledAttribute) as? Bool) ?? true
  out.append(Node(e: e, role: str(e, kAXRoleAttribute), title: str(e, kAXTitleAttribute), desc: str(e, kAXDescriptionAttribute),
                  value: str(e, kAXValueAttribute), ident: str(e, kAXIdentifierAttribute), enabled: en))
  for c in children(e) { walk(c, &out, depth: depth + 1) }
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]) else {
  FileHandle.standardError.write("usage: ax PID dump|text|press LABEL|has LABEL\n".data(using: .utf8)!); exit(2)
}
guard AXIsProcessTrusted() else { print("no Accessibility for this process"); exit(3) }
let app = AXUIElementCreateApplication(pid)
let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
var nodes: [Node] = []
for w in windows { walk(w, &nodes) }
let pressable: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSwitch", "AXToggle"]

func find(_ label: String) -> Node? {
  if let n = nodes.first(where: { pressable.contains($0.role) && ($0.title == label || $0.desc == label || $0.ident == label) }) { return n }
  if let i = nodes.firstIndex(where: { $0.role == "AXStaticText" && ($0.value == label || $0.title == label) }) {
    return nodes[(i + 1)...].first(where: { pressable.contains($0.role) })
  }
  return nodes.first(where: { pressable.contains($0.role) && (!label.isEmpty && ($0.title.hasPrefix(label) || $0.desc.hasPrefix(label))) })
}

switch args[2] {
case "dump":
  print("windows: \(windows.count)")
  for n in nodes where !(n.title.isEmpty && n.desc.isEmpty && n.value.isEmpty && n.ident.isEmpty) {
    print([n.role, n.title, n.desc, n.value, n.ident, n.enabled ? "" : "disabled"].joined(separator: " | "))
  }
case "text":
  for n in nodes where n.role == "AXStaticText" || n.role == "AXTextField" {
    let t = n.value.isEmpty ? n.title : n.value
    if !t.isEmpty { print(t) }
  }
case "press", "has":
  guard args.count >= 4 else { exit(2) }
  guard let n = find(args[3]) else { print("no control '\(args[3])' (\(windows.count) windows)"); exit(1) }
  guard n.enabled else { print("'\(args[3])' is disabled"); exit(1) }
  if args[2] == "has" { print("\(n.role) \(n.title.isEmpty ? n.desc : n.title)"); exit(0) }
  let r = AXUIElementPerformAction(n.e, kAXPressAction as CFString)
  print(r == .success ? "pressed \(n.role) '\(n.title.isEmpty ? n.desc : n.title)'" : "press failed: \(r.rawValue)")
  exit(r == .success ? 0 : 1)
default:
  exit(2)
}
