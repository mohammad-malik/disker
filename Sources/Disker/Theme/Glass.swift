import DiskerCore
import SwiftUI

extension StorageCategory {
    /// Palette from the design mock. Hue carries the meaning, so these are fixed rather than
    /// derived from the system accent — a chart whose colours shift with a user preference
    /// would break its own legend.
    var color: Color {
        switch self {
        case .users: return Color(red: 0.25, green: 0.55, blue: 0.96)
        case .applications: return Color(red: 0.60, green: 0.42, blue: 0.94)
        case .documents: return Color(red: 0.94, green: 0.38, blue: 0.52)
        case .media: return Color(red: 0.98, green: 0.60, blue: 0.24)
        case .pictures: return Color(red: 0.82, green: 0.78, blue: 0.28)
        case .developer: return Color(red: 0.20, green: 0.76, blue: 0.72)
        case .system: return Color(red: 0.30, green: 0.78, blue: 0.48)
        case .other: return Color(red: 0.62, green: 0.66, blue: 0.72)
        }
    }
}

/// Shared surface treatment for the floating panels.
///
/// Apple's guidance puts Liquid Glass on the navigation layer rather than on every surface.
/// The mock glasses everything, so this splits the difference: panels get real glass, but
/// the modifier honours Reduce Transparency by falling back to an opaque material — dense
/// numerics over a busy wallpaper is exactly where this aesthetic stops being readable.
struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(.background, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.separator, lineWidth: 1)
                )
        } else {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}
