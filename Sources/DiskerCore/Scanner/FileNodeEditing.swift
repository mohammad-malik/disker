import Foundation

/// Small, exact edits to a scanned tree.
///
/// Deleting a file used to mean the chart was simply wrong until the user pressed ⌘R and sat
/// through a full re-walk of the volume. Re-walking is the only way to learn what else has
/// changed on disk, but it is a poor way to learn the one thing we already know for certain:
/// the item we just moved to the Trash is gone, and every folder above it is smaller by
/// exactly its size.
///
/// These rebuild only the spine from the root down to the edited node — every untouched
/// subtree is shared with the original, so the cost is proportional to the depth of the edit
/// rather than to the size of the volume. `FileNode` is immutable, which is what makes that
/// sharing safe.
extension FileNode {
    /// Returns this tree without the node at `components`, along with the node removed.
    ///
    /// `nil` if the path does not resolve, which happens when the tree has already moved on
    /// underneath us — a background rescan landing first, say. Callers should treat that as
    /// "nothing to do" rather than as an error.
    public func removingDescendant(at components: [String]) -> (root: FileNode, removed: FileNode)? {
        guard let name = components.first,
            let index = children.firstIndex(where: { $0.name == name })
        else { return nil }

        let child = children[index]
        var updated = children
        let removed: FileNode

        if components.count == 1 {
            removed = child
            updated.remove(at: index)
        } else {
            guard let result = child.removingDescendant(at: Array(components.dropFirst()))
            else { return nil }
            removed = result.removed
            updated[index] = result.root
        }

        return (resized(children: updated, by: removed, adding: false), removed)
    }

    /// Puts `node` back, where `components` is the path it used to occupy including its own
    /// name. The inverse of `removingDescendant(at:)`, so undo restores the chart in the same
    /// step it restores the file.
    ///
    /// Order among siblings is not preserved; the chart sorts by size anyway.
    public func insertingDescendant(_ node: FileNode, at components: [String]) -> FileNode? {
        guard let name = components.first else { return nil }

        if components.count == 1 {
            // Already present — a rescan beat us to it. Re-adding would double-count.
            guard !children.contains(where: { $0.name == name }) else { return self }
            return resized(children: children + [node], by: node, adding: true)
        }

        guard let index = children.firstIndex(where: { $0.name == name }),
            let rebuilt = children[index].insertingDescendant(
                node, at: Array(components.dropFirst()))
        else { return nil }

        // The recursion returns the child untouched when the node was already there. Every
        // ancestor has to notice that and leave its own totals alone, or a no-op insert
        // still inflates the whole spine above it.
        guard rebuilt !== children[index] else { return self }

        var updated = children
        updated[index] = rebuilt
        return resized(children: updated, by: node, adding: true)
    }

    /// A copy of this node carrying `children`, with its own totals moved by `delta`'s.
    ///
    /// Subtraction saturates at zero. It should never be needed — the totals are aggregates
    /// of exactly these children — but a tree that disagrees with itself should show a
    /// too-small folder rather than trap on an unsigned overflow mid-deletion.
    private func resized(children: [FileNode], by delta: FileNode, adding: Bool) -> FileNode {
        FileNode(
            name: name,
            size: adding ? size &+ delta.size : (size > delta.size ? size - delta.size : 0),
            kind: kind,
            flags: flags,
            children: children,
            fileCount: adding
                ? fileCount + delta.fileCount : max(0, fileCount - delta.fileCount),
            accessTime: accessTime)
    }
}
