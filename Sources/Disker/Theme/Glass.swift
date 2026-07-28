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
/// `.glassEffect()` supplies the refraction, but on its own it is nearly invisible against a
/// dark backdrop. Convincing glass needs the optical cues that come with a real edge: a
/// specular sheen where light catches the surface, and a rim that is bright where it faces
/// the light and dim where it turns away. Those are the layers added on top here.
///
/// Apple's guidance keeps glass on the floating navigation layer rather than on every
/// surface. This app leans further into it by design, so the compensation is legibility:
/// text-bearing panels get enough tint that dense numerics stay readable over a busy
/// wallpaper, which is where the aesthetic usually falls apart.
struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = 16
    /// Raises the tint for panels carrying dense text.
    var legibilityTint: Double = 0.10

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.separator, lineWidth: 1))
        } else {
            content
                .background(tintLayer)
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(specularSheen)
                .overlay(refractiveRim)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        }
    }

    /// A slight wash so text keeps contrast against whatever wallpaper is behind.
    private var tintLayer: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                (colorScheme == .dark ? Color.white : Color.white)
                    .opacity(colorScheme == .dark ? legibilityTint * 0.6 : legibilityTint))
    }

    /// Light pooling on the upper surface, falling off toward the middle — the cue that
    /// says "this is a solid slab catching light" rather than a translucent rectangle.
    private var specularSheen: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.22), location: 0.0),
                        .init(color: .white.opacity(0.06), location: 0.28),
                        .init(color: .clear, location: 0.55),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }

    /// The edge. Bright along the top-leading arc where it faces the light, fading to almost
    /// nothing at the bottom-trailing — the asymmetry is what makes an outline read as a
    /// bevelled rim instead of a drawn border.
    private var refractiveRim: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.55), location: 0.0),
                        .init(color: .white.opacity(0.16), location: 0.35),
                        .init(color: .white.opacity(0.04), location: 0.7),
                        .init(color: .white.opacity(0.14), location: 1.0),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
            .allowsHitTesting(false)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16, legibilityTint: Double = 0.10) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, legibilityTint: legibilityTint))
    }
}
