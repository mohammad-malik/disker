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

    /// Drops whole cards rather than truncating their names.
    ///
    /// The strip shares its width with the sidebar and the inspector, and a card reading
    /// "User e…" tells you nothing — the category name is the entire point of it. Showing
    /// fewer, complete cards is more useful than three abbreviated ones, so this picks the
    /// largest count that actually fits.
    private var categoryCards: some View {
        ViewThatFits(in: .horizontal) {
            cards(3)
            cards(2)
            cards(1)
            EmptyView()
        }
    }

    /// The `count` largest categories, each sized to its full name.
    private func cards(_ count: Int) -> some View {
        let top = model.moleReport?.categories
            .sorted { $0.totalSize > $1.totalSize }
            .prefix(count) ?? []

        return HStack(spacing: 12) {
            ForEach(Array(top), id: \.id) { category in
                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(category.totalSize.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Measured at full width, so `ViewThatFits` decides on the real size rather
                // than on a name that has already been squeezed.
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                // A fill, not a second glass layer. These ride on top of the bar's material,
                // and Apple's fix for elements over glass is fills and vibrancy rather than
                // more glass.
                .background(.quaternary, in: .rect(cornerRadius: 11))
                .help(category.items.prefix(6).map(\.name).joined(separator: "\n"))
            }
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
///
/// Explains the hues actually on screen. It used to classify the charted folder's direct
/// children, which held only as long as those children were what the colours came from —
/// drill into `Users` and every child is `Users/<account>`, so the legend collapsed to a
/// single "Users" entry above a chart drawn in five colours. `StorageCategory.totals` reads
/// the same subtree the chart does, and attributes each byte once.
struct CategoryLegend: View {
    let totals: [CategoryTotal]

    var body: some View {
        // The strip shares its width with the sidebar and the inspector, and there are eight
        // categories — enough to run past the chart pane. Same treatment as the cards on the
        // recommendation bar: show the largest number of *whole* entries that fit, largest
        // first, rather than squeezing them all in.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: totals.count, through: 1, by: -1)), id: \.self) { count in
                entries(count)
            }
            EmptyView()
        }
    }

    private func entries(_ count: Int) -> some View {
        HStack(spacing: 18) {
            ForEach(totals.prefix(count)) { entry in
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
                // Measured at full width, so `ViewThatFits` chooses on the real size rather
                // than on a label that has already been squeezed.
                .fixedSize()
            }
        }
    }
}
