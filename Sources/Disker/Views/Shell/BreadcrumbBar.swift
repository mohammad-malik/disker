import DiskerCore
import SwiftUI

/// The path above the chart, as a row of glass capsules floating over it.
///
/// Each crumb is its own Liquid Glass shape sharing the chart's `GlassEffectContainer` and
/// carrying a `glassEffectID` keyed on the folder's path. That is what makes drilling in and
/// out *look* like this material rather than merely use it: a new capsule is derived from the
/// geometry of the one beside it, so the row grows and shrinks by morphing instead of fading.
///
/// The stack spacing deliberately matches the container's. Apple's rule is that a container
/// spaced wider than its interior stack makes the shapes blend at rest; matched, they stay
/// distinct while standing still and only merge while animating — which is exactly the
/// behaviour a path wants.
///
/// There is no track behind them any more. The old recessed fill existed because this row sat
/// inside a glass card and a second glass layer would have been glass on glass; now it floats
/// over the chart itself, so the chart is what it lenses.
struct BreadcrumbBar: View {
    @Bindable var model: AppModel
    let namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, node in
                crumb(node: node, index: index)
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.breadcrumb.count)
    }

    @ViewBuilder
    private func crumb(node: FileNode, index: Int) -> some View {
        let isCurrent = index == model.breadcrumb.count - 1
        let path = model.absolutePath(forDepth: index)

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
            // Emphasis comes from type and vibrancy, not from a second material or a tint.
            .foregroundStyle(isCurrent ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // Applied to the label, so the whole chip is clickable rather than just the
            // glyphs inside it.
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .floatingGlass(in: Capsule(), interactive: true)
        .glassEffectID(path, in: namespace)
        // No hover tracking: `interactive` glass illuminates from within on its own, and
        // spreads that response to the neighbouring shapes in the same container.
        // The breadcrumb names where you are, so it is where people reach for the path.
        // Offered on every crumb, not just the last, so an ancestor's path is reachable
        // without navigating to it first.
        .contextMenu {
            Button("Copy Path") { model.copyPath(depth: index) }
            Button("Reveal in Finder") { model.revealInFinder(depth: index) }
        }
        .help(path)
        .accessibilityLabel(
            isCurrent ? "\(node.name), current folder" : "Go to \(node.name)")
    }
}
