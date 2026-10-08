// What battery.swift takes from the Bridge's main.swift, for the test.
import Foundation
let tickSeconds = 5.0
func log(_ s: String) { print("log: \(s)") }
func same(_ a: Any?, _ b: Any?) -> Bool { "\(a ?? "nil")" == "\(b ?? "nil")" }
