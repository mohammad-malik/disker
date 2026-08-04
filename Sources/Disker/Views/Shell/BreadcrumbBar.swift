import DiskerCore
import SwiftUI

/// The path above the chart, as a row of chips on a recessed track.
///
/// It was previously bare text buttons with 4pt of spacing and no padding, which measured
/// 24×14pt for a crumb named "Data" — under half Apple's 28pt minimum in either direction,
/// on a control whose whole job is to be clicked to go back. The chips exist for that reason
/// first; the track and the glass are what make a row of padded rectangles look deliberate.
///
/// The track is a plain recessed fill rather than another glass layer. This view sits inside
/// the chart panel, which is already glass, and stacking material on material reads as muddy
/// grey rather than as depth — the same trap `GlassPanel` documents. One recessed track with
/// a single glass chip riding in it is the segmented-control idiom, and it gives the active
/// chip something to lens against.
struct BreadcrumbBar: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hoveredIndex: Int?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, node in
                if index > 0 { separator }
                crumb(node: node, index: index)
            }
            Spacer(minLength: 6)
        }
        .padding(3)
        .background(track)
        .animation(.easeOut(duration: 0.12), value: hoveredIndex)
        .animation(.easeOut(duration: 0.2), value: model.breadcrumb.count)
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var track: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if reduceTransparency {
            shape.strokeBorder(.separator, lineWidth: 1)
        } else {
            shape.fill(.quaternary.opacity(0.5))
        }
    }

    @ViewBuilder
    private func crumb(node: FileNode, index: Int) -> some View {
        let isCurrent = index == model.breadcrumb.count - 1
        let isHovered = hoveredIndex == index

        Button {
            model.drillUp(to: index)
        } label: {
            HStack(spacing: 5) {
                // The disk itself is worth naming as a disk; every other crumb is a folder
                // and an icon on each would just be visual noise.
                if index == 0 {
                    Image(systemName: model.selectedVolume?.symbolName ?? "internaldrive")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(node.name)
                    .font(isCurrent ? .headline : .subheadline)
                    .lineLimit(1)
                    // Ancestors truncate before the folder you are actually looking at does.
                    .layoutPriority(isCurrent ? 2 : 1)
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            // Applied to the label, so the whole chip is clickable rather than just the
            // glyphs inside it.
            .contentShape(.rect(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background { chipBackground(isCurrent: isCurrent, isHovered: isHovered) }
        .onHover { hoveredIndex = $0 ? index : (hoveredIndex == index ? nil : hoveredIndex) }
        // The breadcrumb names where you are, so it is where people reach for the path.
        // Offered on every crumb, not just the last, so an ancestor's path is reachable
        // without navigating to it first.
        .contextMenu {
            Button("Copy Path") { model.copyPath(depth: index) }
            Button("Reveal in Finder") { model.revealInFinder(depth: index) }
        }
        .help(model.absolutePath(forDepth: index))
        .accessibilityLabel(
            isCurrent ? "\(node.name), current folder" : "Go to \(node.name)")
    }

    @ViewBuilder
    private func chipBackground(isCurrent: Bool, isHovered: Bool) -> some View {
        if isCurrent {
            // Interactive glass, so the active chip picks up pointer proximity the way the
            // rest of the window's controls do.
            Color.clear.interactiveGlass(cornerRadius: 10, tint: .white.opacity(0.16))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary)
        }
    }
}
