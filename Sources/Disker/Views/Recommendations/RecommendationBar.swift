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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // Floating chrome over the chart, so this is glass — and the chart running beneath
        // it is what the material lenses. Nothing is drawn on top of it: the shadow and the
        // specular edge come from the material, and a hand-drawn rim is what made the old
        // version read as a card.
        .floatingGlass(in: .rect(cornerRadius: 26))
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
                    // Keeps showing the cached figure while a refresh runs. Replacing it
                    // with "Checking with Mole…" for the ~98 seconds that takes would hide
                    // a good answer behind a spinner.
                    Text(
                        model.isLoadingMole
                            ? "\(total.formattedBytes) can be cleaned · rechecking…"
                            : "\(total.formattedBytes) can be cleaned"
                    )
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
            // A fill, not a second glass layer. These ride on top of the bar's material,
            // and Apple's fix for elements over glass is fills and vibrancy rather than
            // more glass.
            .background(.quaternary, in: .rect(cornerRadius: 11))
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
        // The primary action never truncates. Without this the category cards won on the
        // width split and the button read "Clean wi…".
        .fixedSize(horizontal: true, vertical: false)
        .controlSize(.large)
        // Not `.glassProminent`: this button sits on the bar's glass, and stacking the
        // material on itself is the one thing Apple rules out. A prominent bordered button
        // is also what the new design calls for as the primary action on macOS.
        .buttonStyle(.borderedProminent)
        // Not gated on the background dry-run report. The sheet runs its own preview, so
        // waiting on a summary that takes up to a minute only made the button look broken.
        .help("Runs Mole inside Disker, starting with a preview of what it would remove.")
        .accessibilityLabel("Clean with Mole")
    }
}

/// Category legend under the chart.
struct CategoryLegend: View {
    let root: FileNode?
    /// Path components from the scan root down to `root`.
    ///
    /// Must match what the chart was built with. Classifying on the bare child name alone
    /// gave the legend a different answer from the wedges above it once drilled in: inside a
    /// home directory it read `Library` as system-wide `/Library` and filed `Documents` under
    /// "Other", so the swatches disagreed with the colours they were supposed to explain.
    var rootComponents: [String] = []

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
            let category = StorageCategory.classify(components: rootComponents + [child.name])
            sums[category, default: 0] &+= child.size
        }
        return sums.sorted { $0.value > $1.value }.map { (category: $0.key, size: $0.value) }
    }
}
