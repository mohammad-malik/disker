import Foundation

/// A node in the scanned directory tree.
///
/// Immutable and built bottom-up (children complete before their parent), which is what
/// makes it `Sendable` without locking: workers construct disjoint subtrees in parallel
/// and the parent simply adopts the finished results.
///
/// Deliberately carries no parent pointer. Breadcrumbs come from the drill-down stack the
/// UI already maintains, so the tree stays a clean value-semantics structure and we avoid
/// a retain cycle or an `unowned` field that would defeat `Sendable`.
public final class FileNode: Sendable, Codable {
    /// Leaf name only. Full paths are reconstructed by joining the drill-down stack —
    /// storing an absolute path per node would cost hundreds of MB on a full volume scan.
    public let name: String

    /// Bytes actually occupied on disk, including all descendants.
    ///
    /// Derived from `ATTR_FILE_ALLOCSIZE`, not logical length: sparse files and
    /// APFS-compressed files report a logical size that has little to do with what
    /// freeing them would actually reclaim.
    public let size: UInt64

    public let kind: Kind
    public let flags: Flags

    /// Sorted descending by size. Small files may be collapsed into a single
    /// `.aggregate` child — see `ScanOptions.smallFileThreshold`.
    public let children: [FileNode]

    /// Number of files represented, including those folded into aggregates.
    /// Kept so the UI can say "1,204 items" even where individual files were not retained.
    public let fileCount: Int

    /// Most recent access time seen in this subtree, if the filesystem supplied one.
    /// Unreliable on `noatime` volumes — callers must treat `nil` as "unknown", never "old".
    public let accessTime: Date?

    public enum Kind: UInt8, Sendable, Codable {
        case file
        case directory
        case symlink
        /// Synthetic node standing in for many small files that were not retained.
        case aggregate
    }

    public struct Flags: OptionSet, Sendable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Traversal was denied (`EPERM`/`EACCES`). The subtree's real size is unknown and
        /// is reported as zero, so totals are a lower bound. Surface this in the UI rather
        /// than silently under-reporting.
        public static let inaccessible = Flags(rawValue: 1 << 0)
        /// Skipped because it lives on a different device (firmlink, mount, network volume).
        public static let crossedDevice = Flags(rawValue: 1 << 1)
        /// Size was attributed to another path sharing the same inode (hardlink or APFS clone).
        public static let deduplicated = Flags(rawValue: 1 << 2)
    }

    public init(
        name: String,
        size: UInt64,
        kind: Kind,
        flags: Flags = [],
        children: [FileNode] = [],
        fileCount: Int = 1,
        accessTime: Date? = nil
    ) {
        self.name = name
        self.size = size
        self.kind = kind
        self.flags = flags
        self.children = children
        self.fileCount = fileCount
        self.accessTime = accessTime
    }

    public var isDirectory: Bool { kind == .directory }

    /// Directories whose traversal failed, anywhere in this subtree.
    /// Drives the "N items could not be read" notice — without it a missing Full Disk
    /// Access grant looks identical to a genuinely small disk.
    public var inaccessibleCount: Int {
        (flags.contains(.inaccessible) ? 1 : 0)
            + children.reduce(0) { $0 + $1.inaccessibleCount }
    }

    /// Follows `components` down from this node, returning **every** node passed through
    /// rather than only the destination.
    ///
    /// The intermediate nodes are the point. A chart wedge several rings out is several
    /// levels below the chart's root, and the drill stack has to gain all of them at once —
    /// it is what breadcrumbs, path reconstruction, and category colouring are derived from,
    /// so a stack that skips a level is wrong everywhere at once rather than just visually.
    ///
    /// Returns `nil` if any component is missing, which happens when the tree has been
    /// rebuilt by a re-scan under a stale selection.
    public func chain(to components: some Sequence<String>) -> [FileNode]? {
        var cursor = self
        var visited: [FileNode] = []
        for name in components {
            guard let next = cursor.children.first(where: { $0.name == name }) else { return nil }
            visited.append(next)
            cursor = next
        }
        return visited
    }
}

extension FileNode {
    /// Builds a directory node from finished children, applying the retention policy that
    /// keeps a full-volume tree from exhausting memory.
    ///
    /// Everything below `smallFileThreshold`, and everything past `maxChildrenPerDirectory`,
    /// is folded into one synthetic `.aggregate` child. Sizes and counts are preserved
    /// exactly — only per-file identity is lost, and only for files too small to be
    /// individually actionable.
    static func directory(
        name: String,
        rawChildren: [FileNode],
        options: ScanOptions,
        flags: Flags = [],
        accessTime: Date? = nil
    ) -> FileNode {
        let totalSize = rawChildren.reduce(UInt64(0)) { $0 &+ $1.size }
        let totalFiles = rawChildren.reduce(0) { $0 + $1.fileCount }

        // Directories are always retained: they carry the structure the chart is drawn from.
        var retained: [FileNode] = []
        var folded: [FileNode] = []
        for child in rawChildren {
            if child.isDirectory || child.size >= options.smallFileThreshold {
                retained.append(child)
            } else {
                folded.append(child)
            }
        }

        retained.sort { $0.size > $1.size }

        if retained.count > options.maxChildrenPerDirectory {
            folded.append(contentsOf: retained[options.maxChildrenPerDirectory...])
            retained.removeSubrange(options.maxChildrenPerDirectory...)
        }

        if !folded.isEmpty {
            let foldedSize = folded.reduce(UInt64(0)) { $0 &+ $1.size }
            let foldedCount = folded.reduce(0) { $0 + $1.fileCount }
            retained.append(
                FileNode(
                    name: "\(foldedCount) smaller items",
                    size: foldedSize,
                    kind: .aggregate,
                    fileCount: foldedCount
                )
            )
            retained.sort { $0.size > $1.size }
        }

        return FileNode(
            name: name,
            size: totalSize,
            kind: .directory,
            flags: flags,
            children: retained,
            fileCount: totalFiles,
            accessTime: accessTime
        )
    }
}
