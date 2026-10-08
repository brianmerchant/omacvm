import OmacVMWindow
import SwiftUI

/// Where the window's parts end up, for the window pictures' check
/// (RenderVMWindow, WindowLayout.problems). Off in the app: the views stay
/// as they are.
@MainActor
enum LayoutProbe {
    static var on = false
    static var frames: [String: CGRect] = [:]

    /// The parts measured since the last reset, left to right in the hosting view.
    static func boxes() -> [WindowLayout.Box] {
        frames.sorted { $0.key < $1.key }.map { WindowLayout.Box($0.key, minX: Double($0.value.minX), maxX: Double($0.value.maxX)) }
    }
}

extension View {
    /// Records this view's frame under `name` while the pictures are drawn.
    @ViewBuilder func layoutProbe(_ name: String) -> some View {
        if LayoutProbe.on {
            onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { LayoutProbe.frames[name] = $0 }
        } else {
            self
        }
    }
}
