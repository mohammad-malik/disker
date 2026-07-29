import DiskerCore
import SwiftUI

struct SunburstView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hubFraction: CGFloat = 0.30

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let outerRadius = size / 2 - 8
            let innerRadius = outerRadius * hubFraction
            let ringWidth = (outerRadius - innerRadius) / CGFloat(SunburstLayout.Options().maxRings)

            ZStack {
                // One Canvas for every wedge. A view per wedge would mean thousands of
                // SwiftUI nodes and a diff on each hover; Canvas draws them in a single pass.
                Canvas { context, _ in
                    for segment in model.segments {
                        let isActive =
                            segment.id == model.hoveredSegment?.id
                            || segment.id == model.selectedSegment?.id
                        drawSegment(
                            segment, in: &context, center: center,
                            innerRadius: innerRadius, ringWidth: ringWidth,
                            highlighted: isActive)
                    }
                }
                // All pointer handling goes through AppKit. SwiftUI's tap gestures delay a
                // single click until the double-click interval elapses, which made every
                // selection feel sluggish; clickCount on mouse-down has no such wait.
                .overlay {
                    ClickCatcher(
                        onClick: { location, count in
                            let hit = segment(
                                at: location, center: center,
                                innerRadius: innerRadius, ringWidth: ringWidth)
                            if count >= 2 {
                                guard let hit, hit.node.isDirectory, !hit.node.children.isEmpty
                                else { return }
                                withAnimation(
                                    reduceMotion
                                        ? nil : .spring(response: 0.4, dampingFraction: 0.85)
                                ) {
                                    model.drillDown(into: hit.node)
                                }
                            } else {
                                model.selectedSegment = hit
                            }
                        },
                        onRightClick: { location in
                            // Select what was right-clicked so the menu and the inspector
                            // agree about the target.
                            if let hit = segment(
                                at: location, center: center,
                                innerRadius: innerRadius, ringWidth: ringWidth)
                            {
                                model.selectedSegment = hit
                            }
                        },
                        onMove: { location in
                            guard let location else {
                                model.hoveredSegment = nil
                                return
                            }
                            model.hoveredSegment = segment(
                                at: location, center: center,
                                innerRadius: innerRadius, ringWidth: ringWidth)
                        })
                }

                hub(radius: innerRadius)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contextMenu {
                if let segment = model.hoveredSegment ?? model.selectedSegment {
                    Button("Reveal in Finder") { model.revealInFinder(segment) }
                    Button("Copy Path") { model.copyPath(segment) }
                    Divider()
                    Button("Move to Trash", role: .destructive) {
                        model.requestDeletion(of: segment)
                    }
                    // Aggregates stand for many files at once and have no single path to
                    // delete, so the action would be a lie.
                    .disabled(segment.node.kind == .aggregate)
                }
            }
            // The chart is a single accessibility element with a readable summary. Exposing
            // thousands of individual wedges to VoiceOver would be unusable; the inspector
            // and sidebar carry the per-item detail.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
        }
    }

    private var accessibilitySummary: String {
        guard let root = model.currentRoot else { return "Storage chart, no data" }
        let top = root.children.prefix(5)
            .map { "\($0.name), \($0.size.formattedBytes)" }
            .joined(separator: "; ")
        return "Storage chart for \(root.name), \(root.size.formattedBytes). Largest items: \(top)"
    }

    private func drawSegment(
        _ segment: SunburstSegment,
        in context: inout GraphicsContext,
        center: CGPoint,
        innerRadius: CGFloat,
        ringWidth: CGFloat,
        highlighted: Bool
    ) {
        let ringInner = innerRadius + CGFloat(segment.ring) * ringWidth
        let ringOuter = ringInner + ringWidth - 1.5

        // Canvas angles run counter-clockwise from 3 o'clock; layout angles run clockwise
        // from 12. Rotating by -90° converts between them.
        let start = Angle(radians: segment.startAngle - .pi / 2)
        let end = Angle(radians: segment.endAngle - .pi / 2)

        var path = Path()
        path.addArc(center: center, radius: ringOuter, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: ringInner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()

        // Depth is conveyed by lightening the category hue, so a subtree stays visually
        // tied to its parent as it moves outward.
        let depthFade = 0.16 * Double(segment.ring)
        let base = segment.category.color.opacity(highlighted ? 1.0 : 0.88 - depthFade * 0.3)

        // Radial gradient rather than a flat fill: brighter on the inner edge, deeper toward
        // the rim. That is how a curved, slightly translucent surface catches light, and it
        // keeps adjacent rings distinguishable without adding borders.
        context.fill(
            path,
            with: .radialGradient(
                Gradient(colors: [
                    segment.category.color.mixed(with: .white, amount: 0.22)
                        .opacity(highlighted ? 1.0 : 0.92 - depthFade * 0.3),
                    base,
                ]),
                center: center,
                startRadius: ringInner,
                endRadius: ringOuter))

        // Inner highlight along the leading edge of each ring, mimicking light refracting
        // through the thickness of the band.
        var innerEdge = Path()
        innerEdge.addArc(
            center: center, radius: ringInner + 0.5, startAngle: start, endAngle: end,
            clockwise: false)
        context.stroke(innerEdge, with: .color(.white.opacity(0.28)), lineWidth: 1)

        context.stroke(path, with: .color(.black.opacity(0.18)), lineWidth: 0.5)

        if highlighted {
            context.stroke(path, with: .color(.white.opacity(0.95)), lineWidth: 2)
        }

        // Only label wedges with room for a glyph — anything smaller becomes visual noise.
        if segment.ring == 0, segment.sweep > 0.5 {
            let midRadius = (ringInner + ringOuter) / 2
            let angle = segment.midAngle - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * midRadius,
                y: center.y + sin(angle) * midRadius)

            // Frosted badge behind the glyph, as in the design mock. Without it the symbol
            // competes with the wedge colour and reads as a smudge.
            let badgeRadius = min(ringWidth * 0.30, 20)
            let badge = Path(
                ellipseIn: CGRect(
                    x: point.x - badgeRadius, y: point.y - badgeRadius,
                    width: badgeRadius * 2, height: badgeRadius * 2))
            context.fill(badge, with: .color(.white.opacity(0.28)))
            context.stroke(badge, with: .color(.white.opacity(0.45)), lineWidth: 1)

            var symbol = context.resolve(Image(systemName: segment.category.symbolName))
            symbol.shading = .color(.white.opacity(0.95))
            context.draw(symbol, at: point)
        }
    }

    private func segment(
        at location: CGPoint, center: CGPoint, innerRadius: CGFloat, ringWidth: CGFloat
    ) -> SunburstSegment? {
        SunburstLayout.segment(
            at: (x: Double(location.x - center.x), y: Double(location.y - center.y)),
            in: model.segments,
            innerRadius: Double(innerRadius),
            ringWidth: Double(ringWidth))
    }

    /// Follows the pointer: the hub takes on the colour of the wedge under it, which makes
    /// the connection between chart and readout immediate.
    private var hubTint: Color {
        (model.hoveredSegment ?? model.selectedSegment)?.category.color
            ?? StorageCategory.users.color
    }

    @ViewBuilder
    private func hub(radius: CGFloat) -> some View {
        let root = model.currentRoot
        VStack(spacing: 2) {
            Text(root?.size.formattedBytes ?? "—")
                .font(.system(size: max(14, radius * 0.20), weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(model.hoveredSegment?.node.name ?? "Used")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let volume = model.volume {
                Text("\(Int(volume.usedFraction * 100))%")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(radius * 0.18)
        .frame(width: radius * 2, height: radius * 2)
        // Tinted toward the hovered category so the hub reads as a lens over the chart
        // rather than a hole punched through it, and picks up the colour of whatever the
        // pointer is on. Untinted glass here goes black against the dark panel.
        .glassPanel(
            cornerRadius: radius,
            glass: Glass.regular.tint(hubTint.opacity(0.30)).interactive())
        .contentShape(.circle)
        .onTapGesture {
            // Clicking the hub steps back out, mirroring the drill-in gesture.
            if model.drillPath.count > 1 {
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)) {
                    model.drillUp(to: model.drillPath.count - 2)
                }
            }
        }
        .accessibilityLabel("Go up one level")
    }
}
