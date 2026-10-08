import Foundation

/// The app window's sides: one inset left and right for every part of it
/// (title, form, notes, buttons), and the buttons at the end of a row
/// (Change…, Update VM, Start) on one line at the right inset. Checked on
/// the window pictures (`OmacVM --render-vm-window`, a CI step).
public enum WindowLayout {
    /// The VM window's width.
    public static let width: Double = 568
    /// Left, right, top and bottom: macOS's usual window margin.
    public static let inset: Double = 20
    /// What the content has between the insets.
    public static var contentWidth: Double { width - 2 * inset }

    /// Edges this close count as one line.
    public static let tolerance: Double = 1

    /// Where a part of the window is, left to right, in points from the
    /// window's left edge.
    public struct Box: Equatable {
        public var name: String
        public var minX: Double
        public var maxX: Double

        public init(_ name: String, minX: Double, maxX: Double) {
            self.name = name
            self.minX = minX
            self.maxX = maxX
        }
    }

    /// What is wrong with these parts in a window `width` wide: closer than
    /// `inset` to an edge (or past it), and the `trailing` ones not ending
    /// on one line. Empty: all fine.
    public static func problems(_ boxes: [Box], width: Double, trailing: [String], inset: Double = inset) -> [String] {
        var out: [String] = []
        for b in boxes {
            if b.minX < inset - tolerance {
                out.append("\(b.name): \(Int(b.minX.rounded())) pt from the left edge (\(Int(inset)) at least)")
            }
            if width - b.maxX < inset - tolerance {
                out.append("\(b.name): \(Int((width - b.maxX).rounded())) pt from the right edge (\(Int(inset)) at least)")
            }
        }
        let ends = boxes.filter { trailing.contains($0.name) }
        if let first = ends.first, ends.contains(where: { abs($0.maxX - first.maxX) > tolerance }) {
            out.append("right edges not on one line: " + ends.map { "\($0.name) \(Int($0.maxX.rounded()))" }.joined(separator: ", "))
        }
        return out
    }
}
