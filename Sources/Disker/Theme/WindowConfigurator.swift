import AppKit
import SwiftUI

/// Makes the host `NSWindow` transparent so Liquid Glass has something to refract.
///
/// `.glassEffect()` composites against whatever sits behind it. A SwiftUI window is opaque
/// by default, so glass placed on one samples a flat surface and renders as flat grey —
/// visually indistinguishable from a plain fill, which is exactly how the first build looked.
/// Clearing the window background lets the desktop show through and the material do its job.
///
/// `.windowStyle(.hiddenTitleBar)` alone does not do this: it hides the title bar chrome but
/// leaves the background opaque.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view is not in a window yet during make; defer until it has been installed.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // Traffic lights stay standard and functional — never reimplemented.
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Applies the transparent-window treatment. Skipped under Reduce Transparency, where an
    /// opaque window is both the accessible choice and what the glass fallbacks assume.
    func transparentWindowBackground(enabled: Bool) -> some View {
        background(enabled ? WindowConfigurator() : nil)
    }
}
