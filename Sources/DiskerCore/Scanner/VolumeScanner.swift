import Foundation

/// Recursive volume scanner built on `getattrlistbulk(2)`.
///
/// Parallelism is applied at the top level only: the root's immediate subdirectories are
/// distributed across workers, each of which walks its subtree synchronously. Since each
/// worker owns a disjoint subtree and returns a finished immutable node, no locking is
/// needed for the tree itself — only the shared inode registry and progress counters
/// synchronise, and both are designed to be touched rarely.
public struct VolumeScanner: Sendable {
    public let options: ScanOptions

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public enum ScanError: Error, LocalizedError {
        case rootUnreadable(path: String, errno: Int32)

        public var errorDescription: String? {
            switch self {
            case .rootUnreadable(let path, let code):
                return "Could not read \(path): \(String(cString: strerror(code)))"
            }
        }
    }

    public func scan(
        path: String,
        onProgress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanResult {
        let options = self.options
        return try await withCheckedThrowingContinuation { continuation in
            // Blocking syscalls belong off the cooperative pool — occupying its threads
            // for the length of a full-volume walk would starve everything else.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.performScan(
                        path: path, options: options, onProgress: onProgress)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func performScan(
        path: String,
        options: ScanOptions,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> ScanResult {
        let started = Date()
        let rootPath = (path as NSString).standardizingPath

        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            throw ScanError.rootUnreadable(path: rootPath, errno: errno)
        }

        // Firmlinks and mount points, resolved once. See VolumeBoundaries for why the
        // conventional st_dev comparison cannot do this job on APFS volume groups.
        let boundaries =
            options.stayOnDevice
            ? VolumeBoundaries(scanRoot: rootPath) : VolumeBoundaries(explicit: [])

        let registry = InodeRegistry()
        let reporter = ProgressReporter(emit: onProgress)

        // Read the root itself first so its children can be split across workers.
        var topLevel: [BulkEntry] = []
        do {
            try BulkDirectoryReader.read(path: rootPath) { topLevel.append($0) }
        } catch {
            throw ScanError.rootUnreadable(path: rootPath, errno: EACCES)
        }

        let context = ScanContext(
            options: options,
            boundaries: boundaries,
            registry: registry,
            reporter: reporter
        )

        // Directories are the expensive part and get parallelised; loose files at the root
        // are cheap and handled inline.
        let directories = topLevel.filter { $0.isDirectory }
        let files = topLevel.filter { !$0.isDirectory }

        let collector = ResultCollector()
        if !directories.isEmpty {
            DispatchQueue.concurrentPerform(iterations: directories.count) { index in
                let entry = directories[index]
                let childPath = rootPath == "/" ? "/\(entry.name)" : "\(rootPath)/\(entry.name)"
                if let node = walk(entry: entry, path: childPath, context: context) {
                    collector.append(node)
                }
            }
        }

        var children = collector.nodes
        for entry in files {
            if let node = leafNode(for: entry, context: context) { children.append(node) }
        }
        reporter.record(files: files.count, bytes: 0, path: rootPath)

        let root = FileNode.directory(
            name: (rootPath as NSString).lastPathComponent.isEmpty
                ? rootPath : (rootPath as NSString).lastPathComponent,
            rawChildren: children,
            options: options
        )

        return ScanResult(
            root: root,
            rootPath: rootPath,
            duration: Date().timeIntervalSince(started),
            inaccessibleCount: root.inaccessibleCount,
            deduplicatedBytes: registry.deduplicatedBytes
        )
    }

    /// Walks one directory subtree synchronously, returning a finished immutable node.
    private static func walk(entry: BulkEntry, path: String, context: ScanContext) -> FileNode? {
        if context.options.excludedPaths.contains(path) { return nil }

        // A firmlink or mount point. Descending would either double-count (every firmlink
        // under `/` mirrors content that also lives on the data volume) or stall on a
        // remote share. Reported as a zero-size node so the location stays visible.
        if context.boundaries.isBoundary(path) {
            return FileNode(
                name: entry.name, size: 0, kind: .directory,
                flags: .crossedDevice, fileCount: 0
            )
        }

        var entries: [BulkEntry] = []
        do {
            try BulkDirectoryReader.read(path: path) { entries.append($0) }
        } catch {
            // Almost always a missing Full Disk Access grant. Record it and keep going —
            // a partial map with an honest warning beats aborting the whole scan.
            return FileNode(
                name: entry.name, size: 0, kind: .directory,
                flags: .inaccessible, fileCount: 0
            )
        }

        var children: [FileNode] = []
        children.reserveCapacity(entries.count)
        var directFileCount = 0
        var directBytes: UInt64 = 0

        for child in entries {
            if child.isDirectory {
                let childPath = "\(path)/\(child.name)"
                if let node = walk(entry: child, path: childPath, context: context) {
                    children.append(node)
                }
            } else if let node = leafNode(for: child, context: context) {
                children.append(node)
                directFileCount += 1
                directBytes &+= node.size
            }
        }

        context.reporter.record(files: directFileCount, bytes: directBytes, path: path)

        return FileNode.directory(
            name: entry.name,
            rawChildren: children,
            options: context.options,
            accessTime: entry.accessTime
        )
    }

    /// Builds a node for a non-directory entry, applying hardlink/clone deduplication.
    private static func leafNode(for entry: BulkEntry, context: ScanContext) -> FileNode? {
        var size = entry.allocatedSize
        var flags: FileNode.Flags = []

        if entry.linkCount > 1 {
            let isFirstClaim = context.registry.claim(
                device: entry.deviceID, fileID: entry.fileID, size: size)
            if !isFirstClaim {
                // Already counted elsewhere. Keep the node visible so the file still appears
                // where it lives, but contribute zero bytes so totals stay honest.
                size = 0
                flags.insert(.deduplicated)
            }
        }

        return FileNode(
            name: entry.name,
            size: size,
            kind: entry.isSymlink ? .symlink : .file,
            flags: flags,
            fileCount: 1,
            accessTime: entry.accessTime
        )
    }
}

/// Immutable state shared by every worker.
private struct ScanContext: Sendable {
    let options: ScanOptions
    let boundaries: VolumeBoundaries
    let registry: InodeRegistry
    let reporter: ProgressReporter
}

/// Collects finished subtrees from `concurrentPerform` workers.
private final class ResultCollector: @unchecked Sendable {
    private var storage: [FileNode] = []
    private let lock = NSLock()

    func append(_ node: FileNode) {
        lock.lock()
        storage.append(node)
        lock.unlock()
    }

    var nodes: [FileNode] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
