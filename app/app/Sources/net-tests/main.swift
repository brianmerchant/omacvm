// When a running VM changes network (OmacVMNet), without a VM or Xcode:
//   cd app/app && swift run net-tests
// Exit 0 when all pass. CI runs it on every pull request.
import Foundation
import OmacVMNet

var failures = 0
func expect(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { print("FAIL \(what) (line \(line))"); failures += 1 }
}

typealias W = FastNetworkWatch

/// Polls with the given answers, each step done as asked (ok), the steps back.
func run(_ w: inout W, _ ups: [Bool?], ok: Bool = true) -> [W.Step] {
    ups.map { up in
        let s = w.poll(up)
        if s != .none { w.finished(s, ok: ok) }
        return s
    }
}
let down = [Bool?](repeating: false, count: W.window)
let back = [Bool?](repeating: true, count: W.window)

// A connected VM stays on vmnet; a daemon restart (one poll) changes nothing.
var w = W()
expect(run(&w, [true, true, false, true, true, true, true]).allSatisfy { $0 == .none }, "one missed poll: no switch")

// The daemon goes: the user network after a full window, once.
w = W()
var s = run(&w, down)
expect(s.last == .toUser && s.dropLast().allSatisfy { $0 == .none }, "daemon gone: user network after \(W.window) polls")
expect(w.onUser && w.userUp, "on the user network, its card up")
expect(run(&w, down).allSatisfy { $0 == .none }, "still gone: nothing more")

// Back: vmnet's card first, the user card only after the handover.
s = run(&w, back)
expect(s.last == .toVmnet && s.dropLast().allSatisfy { $0 == .none }, "daemon back for a whole window: vmnet card up")
expect(!w.onUser && w.userUp, "the user card is still up right after")
s = run(&w, [Bool?](repeating: true, count: W.handover))
expect(s.allSatisfy { $0 == .none }, "both cards up for \(W.handover) polls")
expect(run(&w, [true]) == [.userDown], "then the user card goes down")
expect(!w.userUp && run(&w, back).allSatisfy { $0 == .none }, "and nothing more after that")

// Busy QMP during the handover: unanswered polls do not count.
w = W()
_ = run(&w, down); _ = run(&w, back)
s = run(&w, [Bool?](repeating: nil, count: W.handover + 3))
expect(s.allSatisfy { $0 == .none } && w.userUp, "unanswered polls do not count toward the handover")
s = run(&w, [Bool?](repeating: true, count: W.handover + 1))
expect(s.last == .userDown, "answered ones do")

// vmnet goes again during the handover: back to the user network (its card
// is still up), no userDown in between.
w = W()
_ = run(&w, down); _ = run(&w, back)
s = run(&w, [true, true] + down)
expect(!s.contains(.userDown), "vmnet lost in the handover: the user card stays")
expect(s.contains(.toUser) && w.onUser && w.userUp, "and the VM goes back to the user network")
// Flapping vmnet (up, down, up ...) never takes the user card down.
w = W()
_ = run(&w, down); _ = run(&w, back)
s = run(&w, [true, true, true, false, true, true, true, false])
expect(!s.contains(.userDown) && w.userUp, "flapping vmnet: the user card stays")
s = run(&w, [Bool?](repeating: true, count: W.handover + 1))
expect(s.last == .userDown && s.dropLast().allSatisfy { $0 == .none }, "until vmnet holds for \(W.handover) polls in a row")

// A failed step is asked for again at every poll until it goes through.
w = W()
s = run(&w, down, ok: false)
expect(s.last == .toUser && !w.done, "failed switch: not done")
expect(w.poll(nil) == .toUser, "asked again at the next poll, also without an answer")
w.finished(.toUser, ok: true)
expect(w.done && w.userUp, "done once it went through")
_ = run(&w, back)
var left = 0
while w.poll(true) == .none { left += 1; if left > 20 { break } }
expect(left == W.handover, "handover of \(W.handover) polls")
w.finished(.userDown, ok: false)
expect(w.poll(true) == .userDown, "a failed userDown is asked for again")
w.finished(.userDown, ok: true)
expect(w.poll(true) == .none, "then nothing")

// A VM that never lost vmnet never takes a user card down.
w = W()
expect(run(&w, back + back).allSatisfy { $0 == .none }, "vmnet from the start: no steps")

if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
