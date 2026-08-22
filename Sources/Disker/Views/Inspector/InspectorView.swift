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
                Divider().opacity(0.5)
                scanNotes
            }
            .padding(16)
        }
        // No width, no material. This is hosted by an `NSSplitViewItem` inspector, which
        // supplies the column sizing and renders the panel itself — a frame and a glass card
        // here would have been a second material inside the first.
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

    /// Facts about the selected item.
    ///
    /// This section previously showed scan-wide statistics regardless of what was selected,
    /// so clicking a file produced a heading with its name above numbers describing the whole
    /// disk. Those belong to the scan, not the item, and have moved to their own section.
    @ViewBuilder
    private var about: some View {
        if let segment = model.selectedSegment ?? model.hoveredSegment {
            let node = segment.node
            VStack(alignment: .leading, spacing: 7) {
                Text("About")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                detailRow("Kind", kindDescription(node))
                detailRow("Category", segment.category.rawValue)

                if node.isDirectory {
                    detailRow("Contains", "\(node.fileCount.formatted()) files")
                    if !node.children.isEmpty {
                        detailRow("Direct items", "\(node.children.count)")
                    }
                }

                if let accessed = node.accessTime {
                    detailRow("Last opened", relative(accessed))
                } else if node.kind == .file {
                    // Distinguishes "never opened" from "the filesystem doesn't record it",
                    // which matters because the recommendations refuse to guess either way.
                    detailRow("Last opened", "Not recorded")
                }

                if node.flags.contains(.deduplicated) {
                    Label(
                        "Shares storage with another file — counted once, so removing this "
                            + "alone frees nothing.",
                        systemImage: "link"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if node.flags.contains(.inaccessible) {
                    Label("Could not be read during the scan.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if node.kind == .aggregate {
                    Label(
                        "Stands for many small files grouped together. Open the folder in "
                            + "Finder to act on them individually.",
                        systemImage: "square.stack.3d.up"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text("Location")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(model.absolutePath(for: segment))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .multilineTextAlignment(.trailing)
        }
    }

    private func kindDescription(_ node: FileNode) -> String {
        switch node.kind {
        case .directory: return "Folder"
        case .symlink: return "Symbolic link"
        case .aggregate: return "Grouped items"
        case .file:
            let ext = (node.name as NSString).pathExtension
            return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
        }
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Scan-wide caveats. Kept separate from About because they describe the measurement,
    /// not whatever happens to be selected — and each one changes how the headline total
    /// should be read, so they stay on screen rather than in a log.
    @ViewBuilder
    private var scanNotes: some View {
        if case .loaded(let result) = model.scanState {
            VStack(alignment: .leading, spacing: 6) {
                Text("This Scan")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(
                    "\(result.root.fileCount.formatted()) files, scanned in "
                        + "\(String(format: "%.1fs", result.duration))."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if result.deduplicatedBytes > 0 {
                    Text(
                        "\(result.deduplicatedBytes.formattedBytes) shared by hardlinks or "
                            + "clones, counted once."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if result.inaccessibleCount > 0 {
                    Label(
                        unreadableNotice(count: result.inaccessibleCount),
                        systemImage: "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.hasFullDiskAccess ? Color.secondary : Color.orange)
                }
            }
        }
    }

    /// Explains the unreadable folders in terms of something the user can act on.
    ///
    /// Only advise granting access when that would actually help. Once the grant is held,
    /// what remains is root-owned system state — `/private/var/folders`, `/private/var/db`
    /// and the like — which no amount of Full Disk Access opens, because it is guarded by
    /// ordinary Unix permissions rather than by TCC. Telling someone who has already granted
    /// it to go and grant it just reads as the app being broken.
    ///
    /// Built in pieces because the type checker gives up on the concatenated ternary.
    private func unreadableNotice(count: Int) -> String {
        if model.hasFullDiskAccess {
            let opening = "\(count) folders are reserved for macOS and can't be read by any app"
            return opening + ", so the total is slightly low. This is normal."
        }
        let opening = "\(count) folders could not be read — the total is a lower bound."
        return opening + " Grant Full Disk Access for a complete picture."
    }

    @ViewBuilder
    private var revealButton: some View {
        if let segment = model.selectedSegment ?? model.hoveredSegment {
            VStack(spacing: 8) {
                Button {
                    model.revealInFinder(segment)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                // Bordered rather than glass: these sit inside the inspector's own glass,
                // and the material is never stacked on itself.
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    model.requestDeletion(of: segment)
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(segment.node.kind == .aggregate)
                .help("Asks for confirmation first. Undo with ⌘Z.")
            }
        }
    }
}
