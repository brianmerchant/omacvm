import CoreGraphics

/// When the strip tells the guest where the pointer is, for the bar's hover
/// reveal (#308): on entering the strip, and each time the pointer goes from
/// a widget to the bar's free space or back. Moves within either send
/// nothing (the guest only needs to know which of the two it is).
struct StripHover {
    private var lastOnTarget: Bool?

    /// The pointer moved to `p` (bar px); true: send it now.
    mutating func moved(to p: CGPoint, targets: [CGRect]) -> Bool {
        let on = targets.contains { $0.contains(p) }
        defer { lastOnTarget = on }
        return on != lastOnTarget
    }

    /// The targets changed (a reveal widened a widget): the next move sends.
    mutating func targetsChanged() { lastOnTarget = nil }

    /// The pointer left the strip.
    mutating func left() { lastOnTarget = nil }
}
