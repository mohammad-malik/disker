import AppKit
import SwiftUI

/// A frosted backdrop that blurs whatever sits behind the window.
///
/// The first attempt cleared the window background entirely. That produced transparency but
/// not glass: with nothing behind them to sample, the panels rendered as flat dark fills and
/// the window read as a hole punched through the screen.
///
/// Real glass needs something to refract. `NSVisualEffectView` in `.behindWindow` blending
/// samples the desktop and blurs it, giving the panels layered on top an actual optical
/// substrate — which is what makes highlights and edge treatments read as material rather
/// than as decoration.
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.isEmphasized = isEmphasized
    }
}
