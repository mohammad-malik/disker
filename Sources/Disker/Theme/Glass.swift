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

/// The app's only custom Liquid Glass.
///
/// Liquid Glass is a *functional layer* that floats above content — toolbars, sidebars,
/// navigation. Apple's rule is that it does not belong in the content layer, and everything
/// the system already draws in glass (toolbar, sidebar, inspector, sheets) is left alone to
/// do so. What remains for us is the one genuine case this app has: the controls that float
/// over the sunburst canvas.
///
/// The material produces its own lensing, specular edge, adaptive shadow and tone-mapped
/// tint. So this modifier deliberately draws *nothing*: no rim stroke, no drop shadow, no
/// gradient, no white "lift" tint. An earlier version added all four, which is what made the
/// panels read as frosted cards rather than as glass — a hand-drawn hairline and a static
/// shadow are exactly the vocabulary the real material replaces.
///
/// It also never wraps the effect in an opacity or a compositing group, and never puts a fill
/// behind it. Each of those flattens the layer the material samples, and refraction is the
/// whole point.
struct FloatingGlass<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var shape: S
    /// Only ever set on the hub. Tint is adaptive tone mapping rather than a colour wash, and
    /// Apple's warning holds: when everything is tinted, nothing stands out.
    var tint: Color?
    var interactive: Bool

    private var glass: Glass {
        // `identity` is the documented no-op, so the accessible path keeps the same view tree
        // and the same view identity — which matters here because these shapes morph.
        guard !reduceTransparency else { return .identity }
        let base = tint.map { Glass.regular.tint($0) } ?? .regular
        return interactive ? base.interactive() : base
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(glass, in: shape)
            // Only ever non-clear when the glass above is `identity`, so this is a fallback
            // surface rather than a fill sitting behind live glass.
            .background(
                reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                in: shape)
    }
}

extension View {
    /// Floats this view above the content layer on Liquid Glass.
    ///
    /// Apply last: SwiftUI anchors the glass to the view's bounds, so padding and any modifier
    /// that changes appearance must already have been applied.
    ///
    /// Uses the `regular` variant throughout. `clear` is non-adaptive and would need its own
    /// dimming layer; every floating element here carries dense figures over a chart whose
    /// colours vary from pale to saturated, which is precisely the case Apple reserves
    /// `regular` for. The two variants are never mixed.
    func floatingGlass(
        in shape: some Shape = Capsule(),
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(FloatingGlass(shape: shape, tint: tint, interactive: interactive))
    }
}
