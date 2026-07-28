import DiskerCore
import SwiftUI

extension StorageCategory {
    /// Palette from the design mock. Hue carries the meaning, so these are fixed rather than
    /// derived from the system accent — a chart whose colours shift with a user preference
    /// would break its own legend.
    var color: Color {
        switch self {
        case .users: return Color(red: 0.29, green: 0.58, blue: 0.99)
        case .applications: return Color(red: 0.65, green: 0.45, blue: 0.98)
        case .documents: return Color(red: 0.97, green: 0.40, blue: 0.55)
        case .media: return Color(red: 1.00, green: 0.62, blue: 0.26)
        case .pictures: return Color(red: 0.88, green: 0.82, blue: 0.30)
        case .developer: return Color(red: 0.22, green: 0.82, blue: 0.78)
        case .system: return Color(red: 0.32, green: 0.83, blue: 0.52)
        case .other: return Color(red: 0.66, green: 0.70, blue: 0.76)
        }
    }
}

extension Color {
    /// Blends toward another colour. Used to lift the inner edge of a chart band so the
    /// ring reads as a curved surface rather than a flat annulus.
    func mixed(with other: Color, amount: Double) -> Color {
        let clamped = max(0, min(1, amount))
        let base = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let target = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(
            red: Double(base.redComponent) * (1 - clamped) + Double(target.redComponent) * clamped,
            green: Double(base.greenComponent) * (1 - clamped)
                + Double(target.greenComponent) * clamped,
            blue: Double(base.blueComponent) * (1 - clamped)
                + Double(target.blueComponent) * clamped)
    }
}

/// Surface treatment for the floating panels.
///
/// This is deliberately thin. An earlier version hand-painted specular gradients, rim
/// highlights, and coloured light pools behind everything — that is 2015-era glassmorphism,
/// and it fought the real material rather than using it. Liquid Glass already does the
/// lensing, the edge specular, and the adaptive tinting; layering fake highlights on top
/// only muddies it.
///
/// So the rule here: `.glassEffect` does the work, and this modifier adds nothing beyond a
/// shadow for elevation and an opaque fallback for Reduce Transparency. Anything that looks
/// like glass should come from the material, not from a gradient.
struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = 16
    /// When nil, the panel uses the standard lifted glass. Pass a value to override entirely.
    var glass: Glass?

    /// A faint white tint mixed into the material.
    ///
    /// Glass shows what is behind it, and behind this window is usually a dark editor or
    /// terminal — so untinted panels go nearly black and the material's character disappears
    /// exactly when it should be most visible. Lifting the tint keeps the surface reading as
    /// glass over a dark backdrop without resorting to a coloured wash behind the window.
    var lift: Double = 0.10

    private var resolvedGlass: Glass {
        if let glass { return glass }
        // Dark backdrops need more help than light ones, which already have plenty to lens.
        let amount = colorScheme == .dark ? lift : lift * 0.4
        return Glass.regular.tint(.white.opacity(amount))
    }

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.separator, lineWidth: 1))
        } else {
            content
                .glassEffect(resolvedGlass, in: .rect(cornerRadius: cornerRadius))
                // A single hairline, uniform weight. Not the multi-stop fake specular this
                // replaced — just enough to define where the pane ends, which the material
                // alone does not do convincingly against a dark background.
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            .white.opacity(colorScheme == .dark ? 0.16 : 0.30),
                            lineWidth: 0.5)
                        .allowsHitTesting(false))
                .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16, glass: Glass? = nil, lift: Double = 0.10)
        -> some View
    {
        modifier(GlassPanel(cornerRadius: cornerRadius, glass: glass, lift: lift))
    }

    /// For controls that should respond to pointer proximity the way system glass does.
    func interactiveGlass(cornerRadius: CGFloat = 12, tint: Color? = nil) -> some View {
        modifier(
            GlassPanel(
                cornerRadius: cornerRadius,
                glass: Glass.regular
                    .tint(tint ?? .white.opacity(0.14))
                    .interactive()))
    }
}
