import AppKit
import SwiftUI

/// Reports clicks with their click count, immediately.
///
/// SwiftUI cannot do this. Attaching both `.onTapGesture` and `.onTapGesture(count: 2)` makes
/// the single-tap handler wait out the system double-click interval before firing, so every
/// selection in the chart lagged by roughly a third of a second. AppKit hands us
/// `NSEvent.clickCount` on mouse-down, which means a first click can act at once and a second
/// click can still be recognised as a double.
///
/// Also carries right-click, so the context menu comes from the same hit test as selection
/// rather than SwiftUI's separate one.
struct ClickCatcher: NSViewRepresentable {
    /// (location in view coordinates, click count)
    let onClick: (CGPoint, Int) -> Void
    let onRightClick: (CGPoint) -> Void
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onClick = onClick
        view.onRightClick = onRightClick
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onClick = onClick
        nsView.onRightClick = onRightClick
        nsView.onMove = onMove
    }

    final class CatcherView: NSView {
        var onClick: ((CGPoint, Int) -> Void)?
        var onRightClick: ((CGPoint) -> Void)?
        var onMove: ((CGPoint?) -> Void)?

        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        /// AppKit's origin is bottom-left; SwiftUI's is top-left.
        private func flipped(_ point: NSPoint) -> CGPoint {
            CGPoint(x: point.x, y: bounds.height - point.y)
        }

        override func mouseDown(with event: NSEvent) {
            // Acting on mouse-down rather than mouse-up is what makes selection feel
            // immediate. clickCount distinguishes the second click of a double.
            onClick?(flipped(convert(event.locationInWindow, from: nil)), event.clickCount)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(flipped(convert(event.locationInWindow, from: nil)))
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(flipped(convert(event.locationInWindow, from: nil)))
        }

        override func mouseExited(with event: NSEvent) {
            onMove?(nil)
        }
    }
}
