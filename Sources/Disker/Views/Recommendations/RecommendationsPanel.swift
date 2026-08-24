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

    /// Which collapsed families are open.
    ///
    /// Held here rather than in each row so it survives scrolling — `List` throws rows away
    /// as they leave the screen, and per-row `@State` went with them, collapsing groups the
    /// user had just opened. Keyed on the cluster's stable id, not on its members, whose ids
    /// are fresh on every analysis pass.
    @State private var expanded: Set<String> = []

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
                    ForEach(group.entries) { entry in
                        switch entry {
                        case .single(let item):
                            RecommendationRow(item: item, model: model)
                        case .cluster(let cluster):
                            ClusterRow(
                                cluster: cluster, model: model,
                                isExpanded: expanded.contains(cluster.id),
                                toggle: { toggle(cluster.id) })
                            if expanded.contains(cluster.id) {
                                ForEach(cluster.items) { item in
                                    RecommendationRow(item: item, model: model, nested: true)
                                }
                            }
                        }
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

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }
}

/// One collapsed family: what it is, how many, and what they come to together.
private struct ClusterRow: View {
    let cluster: RecommendationCluster
    @Bindable var model: AppModel
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)

            Image(systemName: cluster.symbolName)
                .foregroundStyle(.green)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(cluster.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                // Names the biggest one rather than repeating the count. It is the member
                // worth looking at first, and it says what sort of place these came from
                // without opening the group.
                if let largest = cluster.largest, let label = cluster.largestLabel {
                    Text("largest \(largest.size.formattedBytes) in \(label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(cluster.detail)

            Spacer(minLength: 8)

            Text(cluster.totalSize.formattedBytes)
                .font(.callout.weight(.medium))
                .monospacedDigit()

            Button {
                model.requestTrashing(of: cluster)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Move all \(cluster.items.count) to Trash — undo with ⌘Z")
            .accessibilityLabel("Move all \(cluster.items.count) to Trash")
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture(perform: toggle)
        .contextMenu {
            Button(isExpanded ? "Collapse" : "Expand", action: toggle)
            Divider()
            Button("Move All \(cluster.items.count) to Trash", role: .destructive) {
                model.requestTrashing(of: cluster)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(cluster.title), \(cluster.totalSize.formattedBytes). \(cluster.detail)")
        .accessibilityHint(isExpanded ? "Expanded" : "Collapsed. Click to see each one.")
    }
}

private struct RecommendationRow: View {
    let item: Recommendation
    @Bindable var model: AppModel
    /// Set when the row is a member of an expanded family, which indents it under its group.
    var nested = false

    var body: some View {
        HStack(spacing: 10) {
            if nested {
                // Lines the member up under its group's icon rather than its chevron.
                Spacer().frame(width: 20)
            }
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
