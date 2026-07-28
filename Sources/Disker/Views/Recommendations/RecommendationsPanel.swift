import DiskerCore
import SwiftUI

/// Disker's own cleanup suggestions, grouped by how much scrutiny each deserves.
///
/// Distinct from the Mole strip: Mole knows about system and app caches, while this works
/// from the scanned tree and finds things specific to how the disk is actually laid out —
/// a 4 GB node_modules in a project abandoned last year.
struct RecommendationsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if model.recommendations.isEmpty {
                    ContentUnavailableView(
                        "Nothing obvious to clean",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "Disker found no build artefacts or stale large files. "
                                + "The Mole panel may still have caches to clear.")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(tiers, id: \.self) { tier in
                        section(for: tier)
                    }
                }
            }
            .padding(16)
        }
    }

    private var tiers: [Recommendation.Tier] {
        var seen: [Recommendation.Tier] = []
        for item in model.recommendations where !seen.contains(item.tier) {
            seen.append(item.tier)
        }
        return seen
    }

    private func section(for tier: Recommendation.Tier) -> some View {
        let items = model.recommendations.filter { $0.tier == tier }
        let total = items.reduce(UInt64(0)) { $0 &+ $1.size }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tier.label)
                    .font(.headline)
                Spacer()
                Text(total.formattedBytes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ForEach(items) { item in
                RecommendationRow(item: item, model: model)
            }
        }
    }
}

private struct RecommendationRow: View {
    let item: Recommendation
    @Bindable var model: AppModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbolName)
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                // Location rather than the rationale: titles collide often, and the row
                // carries a destructive action, so the user needs to know *which* one.
                // The rationale moves to the tooltip.
                Text(item.displayPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(item.detail)

            Spacer(minLength: 8)

            Text(item.size.formattedBytes)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)

            // Revealed on hover to keep a destructive control from sitting under the
            // pointer during ordinary scanning of the list.
            if isHovered {
                Button {
                    model.trash(item)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Move to Trash — undo with ⌘Z")
                .accessibilityLabel("Move \(item.title) to Trash")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    URL(fileURLWithPath: item.path)
                ])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.title) in \(item.displayPath), \(item.size.formattedBytes). \(item.detail)")
    }

    private var tint: Color {
        switch item.tier {
        case .safe: return .green
        case .review: return .orange
        case .informational: return .secondary
        }
    }
}
