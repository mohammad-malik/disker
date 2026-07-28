import DiskerCore
import SwiftUI

/// The bottom action strip: what Mole reports as reclaimable, plus the handoff button.
struct RecommendationBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            summary
            Divider().frame(height: 40)
            categoryCards
            Spacer(minLength: 0)
            cleanButton
        }
        .padding(14)
        .glassPanel()
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommendations")
                    .font(.headline)
                switch model.moleReport {
                case .parsed(_, let total):
                    Text("\(total.formattedBytes) can be cleaned")
                        .font(.callout)
                        .foregroundStyle(.tint)
                case .unparseable(let reason):
                    // Never substitute a guess here: this figure precedes a deletion.
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                case nil:
                    Text(model.isLoadingMole ? "Checking with Mole…" : "Not checked yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 200, alignment: .leading)
    }

    @ViewBuilder
    private var categoryCards: some View {
        // Largest few categories, since the strip has limited width.
        let top = model.moleReport?.categories
            .sorted { $0.totalSize > $1.totalSize }
            .prefix(3) ?? []

        ForEach(Array(top), id: \.id) { category in
            VStack(alignment: .leading, spacing: 3) {
                Text(category.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(category.totalSize.formattedBytes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .interactiveGlass(cornerRadius: 11)
            .help(category.items.prefix(6).map(\.name).joined(separator: "\n"))
        }
    }

    private var cleanButton: some View {
        Button {
            model.launchMoleCleanup()
        } label: {
            Label("Clean with Mole", systemImage: "wand.and.sparkles")
                .padding(.horizontal, 6)
        }
        .controlSize(.large)
        // The system's own glass button, rather than a tinted rectangle. It picks up the
        // same lensing as the panels, so the primary action belongs to the surface it sits on.
        .buttonStyle(.glassProminent)
        // Not gated on the background dry-run report. The sheet runs its own preview, so
        // waiting on a summary that takes up to a minute only made the button look broken.
        .help("Runs Mole inside Disker, starting with a preview of what it would remove.")
        .accessibilityLabel("Clean with Mole")
    }
}

/// Category legend under the chart.
struct CategoryLegend: View {
    let root: FileNode?

    var body: some View {
        HStack(spacing: 18) {
            ForEach(totals, id: \.category) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.category.color)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.category.rawValue)
                            .font(.caption)
                        Text(entry.size.formattedBytes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var totals: [(category: StorageCategory, size: UInt64)] {
        guard let root else { return [] }
        var sums: [StorageCategory: UInt64] = [:]
        for child in root.children {
            let category = StorageCategory.classify(components: [child.name])
            sums[category, default: 0] &+= child.size
        }
        return sums.sorted { $0.value > $1.value }.map { (category: $0.key, size: $0.value) }
    }
}
