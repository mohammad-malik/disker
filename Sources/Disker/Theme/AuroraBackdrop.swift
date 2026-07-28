import SwiftUI

/// Soft coloured light behind the glass panels.
///
/// Glass only looks like glass when there is something worth refracting. Relying on the
/// user's wallpaper makes the whole app's appearance a lottery: over a dark terminal — which
/// is what a developer usually has behind their windows — every panel renders as a flat grey
/// slab no matter how carefully the material is configured.
///
/// So Disker supplies its own light. Broad, heavily blurred colour pools sit above the
/// window's frosted backdrop and below the panels, giving the glass a gradient to bend and
/// producing the depth the design depends on regardless of what is behind the window.
/// Opacity stays low enough that the desktop still reads through.
struct AuroraBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Hues drawn from the chart palette, so the backdrop feels like part of the same system
    /// rather than arbitrary decoration.
    private var pools: [(color: Color, x: CGFloat, y: CGFloat, scale: CGFloat)] {
        [
            (Color(red: 0.29, green: 0.52, blue: 0.99), 0.18, 0.16, 0.85),
            (Color(red: 0.62, green: 0.40, blue: 0.98), 0.82, 0.24, 0.70),
            (Color(red: 0.20, green: 0.72, blue: 0.86), 0.72, 0.86, 0.75),
            (Color(red: 0.96, green: 0.42, blue: 0.60), 0.14, 0.88, 0.55),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                ForEach(Array(pools.enumerated()), id: \.offset) { _, pool in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    pool.color.opacity(colorScheme == .dark ? 0.55 : 0.40),
                                    pool.color.opacity(0),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: side * pool.scale * 0.5)
                        )
                        .frame(width: side * pool.scale, height: side * pool.scale)
                        .position(
                            x: geometry.size.width * pool.x,
                            y: geometry.size.height * pool.y)
                }
            }
            // A single large blur over the composed pools keeps the edges from banding and
            // makes them read as light rather than as overlapping discs.
            .blur(radius: side * 0.09)
            .opacity(colorScheme == .dark ? 0.55 : 0.42)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
