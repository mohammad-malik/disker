import DiskerCore
import SwiftUI

/// Disker's own cleanup suggestions, grouped by how much scrutiny each deserves.
///
/// Distinct from the Mole strip: Mole knows about system and app caches, while this works
/// from the scanned tree and finds things specific to how the disk is actually laid out —
/// a 4 GB node_modules in a project abandoned last year.
///
/// Built on `List` rather than `ScrollView` + `LazyVStack`. The previous version nested a
/// plain `ForEach` inside each tier's `VStack`, so the outer `LazyVStack` had only three
/// children and every one of the ~1,300 rows was constructed up front — the laziness bought
/// nothing. `List` is backed by `NSTableView` and only realises visible rows, which is what
/// makes a list this size usable at all.
struct RecommendationsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.recommendations.isEmpty {
                ContentUnavailableView(
                    "Nothing obvious to clean",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Disker found no build artefacts or stale large files. "
                            + "The Mole panel may still have caches to clear.")
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.recommendationGroups) { group in
                Section {
                    ForEach(group.items) { item in
                        RecommendationRow(item: item, model: model)
                    }
                } header: {
                    HStack {
                        Text(group.tier.label)
                            .font(.headline)
                        Spacer()
                        Text(group.totalSize.formattedBytes)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        // `hard` rather than `soft`: this is a dense list of figures under a floating glass
        // toolbar, and the crisper boundary is the macOS-leaning choice for text and controls
        // that scroll beneath one.
        .scrollEdgeEffectStyle(.hard, for: .top)
    }
}

private struct RecommendationRow: View {
    let item: Recommendation
    @Bindable var model: AppModel

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

            // Always present rather than revealed on hover. A per-row hover `@State` meant
            // every pointer movement invalidated rows, which at this list size was a large
            // part of why the view became unusable.
            Button {
                model.act(on: item)
            } label: {
                Image(systemName: actionSymbol)
            }
            .buttonStyle(.borderless)
            .help(actionHelp)
            .accessibilityLabel("\(actionTitle), \(item.title)")
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
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
            Button(actionTitle, role: .destructive) { model.act(on: item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.title) in \(item.displayPath), \(item.size.formattedBytes). \(item.detail)")
    }

    /// The row's button describes what it actually does.
    ///
    /// Emptying the Trash is neither a move nor reversible, and labelling it "Move to Trash —
    /// undo with ⌘Z" promised both. It also promised something impossible: the Trash cannot
    /// be moved into itself, which is exactly what the row used to attempt.
    private var actionTitle: String {
        switch item.action {
        case .moveToTrash: return "Move to Trash"
        case .emptyTrash: return "Empty the Trash"
        }
    }

    private var actionSymbol: String {
        switch item.action {
        case .moveToTrash: return "trash"
        case .emptyTrash: return "trash.slash"
        }
    }

    private var actionHelp: String {
        switch item.action {
        case .moveToTrash: return "Move to Trash — undo with ⌘Z"
        case .emptyTrash: return "Delete everything in the Trash for good — this cannot be undone"
        }
    }

    private var tint: Color {
        switch item.tier {
        case .safe: return .green
        case .review: return .orange
        case .informational: return .secondary
        }
    }
}
