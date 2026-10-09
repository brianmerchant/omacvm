// Offline test of StripHover (#308): the guest hears of the pointer on
// entering the strip and when it crosses between a widget and free space.
import CoreGraphics
import Foundation

var fails = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok   \(what)" : "FAIL \(what)")
    if !ok { fails += 1 }
}
let widget = CGRect(x: 100, y: 0, width: 30, height: 26)
var h = StripHover()
check(h.moved(to: CGPoint(x: 40, y: 10), targets: [widget]), "entering on free space: sent")
check(!h.moved(to: CGPoint(x: 60, y: 10), targets: [widget]), "moving on free space: nothing")
check(h.moved(to: CGPoint(x: 110, y: 10), targets: [widget]), "onto a widget: sent")
check(!h.moved(to: CGPoint(x: 120, y: 10), targets: [widget]), "along the widget: nothing")
check(h.moved(to: CGPoint(x: 140, y: 10), targets: [widget]), "back to free space: sent")
h.targetsChanged()
check(h.moved(to: CGPoint(x: 141, y: 10), targets: [widget]), "after new targets: sent again")
h.left()
check(h.moved(to: CGPoint(x: 110, y: 10), targets: [widget]), "entering again on a widget: sent")
if fails > 0 { print("\(fails) failed"); exit(1) }
print("all StripHover checks passed")
