import CoreGraphics

/// The menu bar's bottom edge on one screen, in Accessibility's top-left coordinates, with the horizontal extent
/// of that screen.
struct BarEdge: Equatable, Sendable {
    let xRange: Range<Double>
    let bottom: Double
}

/// A screen as AppKit reports it: its frame in bottom-left coordinates, and the height of its menu bar.
struct ScreenBar: Equatable, Sendable {
    let frame: CGRect
    let barHeight: Double
}

enum BarEdges {
    /// The room the display reserves for its bar, `frame.maxY - visibleFrame.maxY`, whenever there is any. It is 0
    /// while the bar auto-hides; then a notched display's bar is as tall as its safe-area top inset and every other
    /// display's is the status bar's thickness.
    static func barHeight(reserved: Double, safeAreaTop: Double, statusBarThickness: Double) -> Double {
        if reserved > 0 { return reserved }
        return safeAreaTop > 0 ? safeAreaTop : statusBarThickness
    }

    /// One edge per screen. `screens` starts with the primary screen, whose top-left corner is Accessibility's
    /// origin; a screen's edge sits `barHeight` below its own top.
    static func edges(for screens: [ScreenBar]) -> [BarEdge] {
        guard let primary = screens.first else { return [] }
        return screens.map { screen in
            BarEdge(
                xRange: screen.frame.minX..<screen.frame.maxX,
                bottom: primary.frame.maxY - screen.frame.maxY + screen.barHeight
            )
        }
    }
}
