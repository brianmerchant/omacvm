/// When a running VM changes network (Runner.watchFastNetwork), apart from
/// QMP so it can be tested without a VM: `swift run net-tests`.
///
/// Every 3 s the app asks QEMU whether it is connected to omacvm-netd and
/// feeds the answer to poll(), which says what to do now. The VM goes to
/// the user network when most of the last `window` polls saw no connection,
/// and back to vmnet when all of them saw one. Back is make before break:
/// the vmnet card's link goes up first and the user network's card stays up
/// for `handover` more polls, so the guest has its vmnet address before the
/// user network goes (at once, the guest had no network for its DHCP, about
/// 8 s). A step that failed (QMP busy) is asked for again at the next poll.
public struct FastNetworkWatch: Equatable {
    public enum Step: Equatable {
        case none
        case toUser    // user card up (added the first time), vmnet card's link down
        case toVmnet   // vmnet card's link up; the user card stays up for now
        case userDown  // the user card's link down (the handover is over)
    }

    /// Polls in the window (one every 3 s): a daemon restart (about a second)
    /// never fills it, a refusing or missing daemon does in 9-15 s.
    public static let window = 5
    /// Polls that saw vmnet connected with both cards up after the vmnet card
    /// came back (12-15 s; the guest's DHCP took about 8 s).
    public static let handover = 4

    public private(set) var recent: [Bool] = []
    /// The network the VM should be on.
    public private(set) var onUser = false
    /// The last step to it went through.
    public private(set) var done = true
    /// The user network's card is up.
    public private(set) var userUp = false
    /// Polls in a row (vmnet connected) left before the user card goes down.
    public private(set) var handoverLeft = 0

    public init() {}

    /// One poll: up is nil when QMP did not answer.
    public mutating func poll(_ up: Bool?) -> Step {
        if let up {
            recent.append(up)
            if recent.count > Self.window { recent.removeFirst() }
        }
        let ups = recent.filter { $0 }.count
        if recent.count == Self.window {
            if !onUser, ups * 2 < recent.count { onUser = true; done = false }
            else if onUser, ups == recent.count { onUser = false; done = false }
        }
        if !done { return onUser ? .toUser : .toVmnet }
        // The user card goes only after `handover` polls in a row that saw
        // vmnet connected (a vmnet that fails again starts the count over,
        // and the window takes the VM back if it stays down).
        if !onUser, userUp {
            if up == false { handoverLeft = Self.handover; return .none }
            if up == true {
                if handoverLeft > 0 { handoverLeft -= 1; return .none }
                return .userDown
            }
        }
        return .none
    }

    /// What became of the step poll() asked for.
    public mutating func finished(_ step: Step, ok: Bool) {
        guard ok else { return }   // done stays false (or the user card up): asked again
        switch step {
        case .toUser:
            done = true; recent.removeAll(); userUp = true; handoverLeft = 0
        case .toVmnet:
            done = true; recent.removeAll(); handoverLeft = userUp ? Self.handover : 0
        case .userDown:
            userUp = false
        case .none:
            break
        }
    }
}
