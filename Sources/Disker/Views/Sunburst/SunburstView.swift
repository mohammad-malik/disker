import DiskerCore
import SwiftUI

struct SunburstView: View {
    @Bindable var model: AppModel
    /// Shared with the breadcrumb, so the hub and the path render in one sampling pass and
    /// respond to each other's interaction.
    let namespace: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the hub's own affordance. Kept here rather than read from the model: nothing
    /// outside this view needs to know the pointer is over the hub.
    @State private var hubHovered = false

    private let hubFraction: CGFloat = 0.30

    /// How far the hub is drawn beyond the chart's inner hole, as a multiple of it.
    ///
    /// The overlap is the point: glass with nothing behind it renders as a flat disc, so the
    /// first ring has to pass under the hub's edge for it to lens anything. Anything that
    /// must stay clear of the hub — the ring-0 glyphs — has to be placed against this too.
    private let hubOverlap: CGFloat = 1.22

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
                                    model.drillDown(into: hit)
                                }
                            } else {
                                withAnimation(
                                    reduceMotion
                                        ? nil : .spring(response: 0.3, dampingFraction: 0.9)
                                ) {
                                    model.selectFromClick(hit)
                                }
                            }
                        },
                        onRightClick: { location in
                            // Select what was right-clicked so the menu and the inspector
                            // agree about the target.
                            if let hit = segment(
                                at: location, center: center,
                                innerRadius: innerRadius, ringWidth: ringWidth)
                            {
                                withAnimation(
                                    reduceMotion
                                        ? nil : .spring(response: 0.3, dampingFraction: 0.9)
                                ) {
                                    model.selectFromClick(hit)
                                }
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

                // Deliberately wider than the hole it sits in, so the first ring passes
                // beneath its edge. Sized to `innerRadius` exactly, the hub covered the one
                // part of the chart with nothing in it — glass with nothing behind it is
                // just a dark disc, which is precisely what it looked like.
                hub(radius: innerRadius * hubOverlap)
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
            // The hub's own label is swallowed by the element above, so its action is
            // republished here — otherwise selecting the charted folder would be reachable
            // by pointer only.
            .accessibilityAction(named: "Select this folder") { model.selectCurrentRoot() }
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
            // Fit the glyph into the band that is actually visible.
            //
            // The hub is deliberately drawn wider than the chart's inner hole so the first
            // ring passes beneath its edge and the glass has something to lens. That edge
            // reaches past the middle of ring 0, where these glyphs naturally sit, so they
            // were being clipped by it.
            //
            // The leftover band is only just wider than a full-size badge, so sliding the
            // glyph outward at its usual size drops it off the ring's far edge instead —
            // trading a clipped symbol for no symbol at all. Sizing it to the band keeps it
            // whole and keeps the hub's overlap.
            let bandInner = max(ringInner, innerRadius * hubOverlap)
            let fits = (ringOuter - bandInner) / 2 - 1
            let badgeRadius = min(ringWidth * 0.30, 20, fits)

            // Below this it is a dot rather than a symbol, and reads as a blemish on the
            // wedge rather than as a label.
            guard badgeRadius >= 7 else { return }

            let placement = bandInner + badgeRadius + 1
            let angle = segment.midAngle - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * placement,
                y: center.y + sin(angle) * placement)

            // Frosted badge behind the glyph, as in the design mock. Without it the symbol
            // competes with the wedge colour and reads as a smudge.
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

    /// The third line: a wedge's share of the folder being charted, or how full the disk is
    /// when nothing is under the pointer.
    ///
    /// Naming what the percentage is *of* matters here. A bare "1.4%" beneath a folder name
    /// invites reading it as a share of the whole disk, which it is not — it is a share of
    /// whatever the chart is currently rooted at.
    private func hubCaption(root: FileNode?, focus: SunburstSegment?) -> String? {
        // The charted folder is not a share of itself. Selecting it from the hub made the
        // readout say "Data — 100.0% of Data", so the folder falls back to the disk figure,
        // which is the one fact about it the chart does not already state.
        if let focus, focus.node !== root {
            guard let total = root?.size, total > 0 else { return nil }
            let share = Double(focus.node.size) / Double(total) * 100
            let name = root?.name ?? "this folder"
            // Rounding a sliver to "0.0%" reads as "nothing", which is not the same as
            // "too small to show".
            return share < 0.05
                ? "under 0.1% of \(name)"
                : String(format: "%.1f%% of %@", share, name)
        }
        guard let volume = model.volume else { return nil }
        return "\(Int(volume.usedFraction * 100))% of the disk used"
    }

    /// Follows the pointer: the hub takes on the colour of the wedge under it, which makes
    /// the connection between chart and readout immediate.
    private var hubTint: Color {
        (model.hoveredSegment ?? model.selectedSegment)?.category.color
            ?? StorageCategory.users.color
    }

    /// Whatever the hub is currently describing: the wedge under the pointer, the selected
    /// one, or the chart's own root when neither applies. Matches `hubTint`, so the colour
    /// and the figures always refer to the same thing.
    private var hubFocus: SunburstSegment? {
        model.hoveredSegment ?? model.selectedSegment
    }

    @ViewBuilder
    private func hub(radius: CGFloat) -> some View {
        let root = model.currentRoot
        let focus = hubFocus
        let isSelected = model.selectedSegment?.id == -1
        VStack(spacing: 2) {
            // The figure and the label have to describe the same thing. The size was always
            // the chart root's while the name followed the pointer, so hovering a 3 GB
            // folder inside a 212 GB volume read as "Library — 212.03 GB".
            Text((focus?.node.size ?? root?.size)?.formattedBytes ?? "—")
                .font(.system(size: max(14, radius * 0.20), weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(focus?.node.name ?? root?.name ?? "Used")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            // The third line is where the hub says what clicking it does. A circle of
            // figures gives no hint that it is a control at all, and the action it performs
            // now — selecting the folder being charted — has no other entry point, so the
            // hint replaces the caption while the pointer is on it rather than waiting for a
            // tooltip.
            if hubHovered, root != nil {
                // Text alone, no glyph. A `Label` centres the icon and the text *together*,
                // which pushed the words about half a glyph-width right of the size and name
                // stacked above them — three lines in a circle, and the middle one visibly
                // off-axis. The pointer cursor and the hub's lift already say "clickable"; the
                // symbol was buying nothing worth breaking the column for.
                Text(isSelected ? "Selected" : "Click to select this folder")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else if let caption = hubCaption(root: root, focus: focus) {
                Text(caption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(radius * 0.18)
        .frame(width: radius * 2, height: radius * 2)
        // The one tinted surface in the app. Tint is adaptive tone mapping rather than a
        // colour wash — it remaps a range of tones against the brightness underneath — so a
        // light touch is enough to tie the readout to the wedge the pointer is on. Heavier
        // than this and it stops reading as glass and starts reading as coloured plastic,
        // and Apple's warning applies: when everything is tinted, nothing stands out.
        .floatingGlass(in: Circle(), tint: hubTint.opacity(0.18), interactive: true)
        .glassEffectID("hub", in: namespace)
        // A hair larger under the pointer, so the shape itself answers "is this clickable?"
        // before the label does. Small enough that the ring beneath the hub's overhang does
        // not visibly shift.
        .scaleEffect(hubHovered ? 1.02 : 1)
        .animation(
            reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85),
            value: hubHovered)
        // Hit testing stays at the hole's real radius. The extra 22% exists to give the
        // material something to lens, and it should not also swallow clicks on the first
        // ring that now passes underneath it.
        .contentShape(Circle().scale(1 / hubOverlap))
        .onHover { inside in
            hubHovered = inside
            // The pointer is the other half of the affordance, and it is the half that
            // works before the user has read anything.
            if inside {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onTapGesture {
            // Selects the folder the chart is centred on — the one thing on screen that has
            // no wedge to click. Stepping back out used to live here, which made the hub the
            // only control whose click undid the gesture that reached it; the breadcrumb
            // above already goes up, as does ⌘↑.
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                model.selectCurrentRoot()
            }
        }
        .help(
            root.map { "Select \($0.name) — shows its details in the inspector" }
                ?? "Select this folder")
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(root.map { "Select \($0.name)" } ?? "Select this folder")
    }
}
