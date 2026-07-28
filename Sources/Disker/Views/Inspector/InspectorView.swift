import DiskerCore
import SwiftUI

struct InspectorView: View {
    @Bindable var model: AppModel

    private var focus: FileNode? {
        model.selectedSegment?.node ?? model.hoveredSegment?.node ?? model.currentRoot
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let focus, !focus.children.isEmpty {
                    largestItems(of: focus)
                }
                about
                revealButton
            }
            .padding(16)
        }
        .frame(width: 300)
        .glassPanel()
    }

    @ViewBuilder
    private var header: some View {
        if let focus {
            HStack(spacing: 12) {
                Image(systemName: focus.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        (model.selectedSegment ?? model.hoveredSegment)?.category.color ?? .accentColor
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(focus.size.formattedBytes)
                        if let share = shareOfParent(focus) {
                            Text(share).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                Spacer()
            }
        }
    }

    private func shareOfParent(_ node: FileNode) -> String? {
        guard let root = model.currentRoot, root.size > 0, node !== root else { return nil }
        return String(format: "%.1f%%", Double(node.size) / Double(root.size) * 100)
    }

    private func largestItems(of node: FileNode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Largest Items")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            ForEach(Array(node.children.prefix(6).enumerated()), id: \.offset) { _, child in
                HStack(spacing: 8) {
                    Image(systemName: iconName(for: child))
                        .foregroundStyle(.tint)
                        .frame(width: 16)
                    Text(child.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(child.size.formattedBytes)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.callout)
            }
        }
    }

    private func iconName(for node: FileNode) -> String {
        switch node.kind {
        case .directory: return "folder.fill"
        case .aggregate: return "ellipsis.circle.fill"
        case .symlink: return "arrow.turn.up.right"
        case .file: return "doc.fill"
        }
    }

    @ViewBuilder
    private var about: some View {
        if case .loaded(let result) = model.scanState {
            VStack(alignment: .leading, spacing: 6) {
                Text("About")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text("\(result.root.fileCount.formatted()) files, scanned in \(String(format: "%.1fs", result.duration)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Both caveats change how the headline number should be read, so they belong
                // on screen rather than buried in a log.
                if result.deduplicatedBytes > 0 {
                    Text("\(result.deduplicatedBytes.formattedBytes) shared by hardlinks or clones, counted once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if result.inaccessibleCount > 0 {
                    Label(
                        "\(result.inaccessibleCount) folders could not be read — the total is a lower bound. Grant Full Disk Access for a complete picture.",
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var revealButton: some View {
        if let segment = model.selectedSegment ?? model.hoveredSegment {
            Button {
                model.revealInFinder(segment)
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.glass)
        }
    }
}
