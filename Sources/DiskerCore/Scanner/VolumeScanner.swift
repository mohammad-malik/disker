import Foundation

/// Recursive volume scanner built on `getattrlistbulk(2)`.
///
/// Traversal runs on an explicit pool of worker threads pulling from one shared stack of
/// directories, rather than by recursing and fanning out at each level. Workers only ever
/// touch the shared stack, the inode registry, and the progress counters; each finished
/// directory is assembled into an immutable `FileNode` exactly once, by whichever worker
/// happens to complete its last child.
///
/// **Why a work queue rather than nested fan-out.** This first parallelised only the root's
/// immediate children, which made a scan run at the speed of its single largest subtree.
/// Real disks are enormously lopsided — on the machine this was developed against, `Users`
/// held 139 GB of 205 GB — so one thread walked two thirds of the disk while the rest sat
/// idle after a second or two. A full scan took 31s at 27% CPU, about one core of eight.
///
/// The obvious repair, calling `DispatchQueue.concurrentPerform` at every level instead of
/// just the root, does not work, and it is worth recording why so nobody tries it again.
/// `concurrentPerform` runs its iterations on the calling thread plus whatever pool threads
/// are free; once the outer region has claimed the pool, an inner region finds nothing spare
/// and quietly runs its iterations on the caller alone — that is, serially. Measured with a
/// deliberately generous fan-out budget that recorded *zero* refusals, `Users` still took
/// 27.0s inside a whole-volume scan against 16.1s when scanned by itself. The nesting bought
/// nothing; the pool was the ceiling all along.
///
/// The work parallelises well once the parallelism is real, because it is bound by syscall
/// latency rather than by disk bandwidth or CPU. Over one identical set of directories with
/// the cache equally warm, serial traversal took 11.9s at 35% CPU against 5.1s at 78%.
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

        // Read the root up front rather than handing it to a worker, so an unreadable root
        // is reported as an error instead of silently becoming an empty scan.
        var topLevel: [BulkEntry] = []
        do {
            try BulkDirectoryReader.read(path: rootPath) { topLevel.append($0) }
        } catch {
            throw ScanError.rootUnreadable(path: rootPath, errno: EACCES)
        }

        let queue = TraversalQueue()
        let context = ScanContext(
            options: options,
            boundaries: boundaries,
            registry: InodeRegistry(),
            reporter: ProgressReporter(emit: onProgress),
            queue: queue
        )

        let rootName = (rootPath as NSString).lastPathComponent
        let rootTask = DirectoryTask(
            name: rootName.isEmpty ? rootPath : rootName,
            path: rootPath,
            accessTime: nil,
            parent: nil
        )

        expand(task: rootTask, entries: topLevel, context: context)
        queue.run(workerCount: options.workerCount) { task in
            process(task: task, context: context)
        }

        // Set by the worker that finalised the root, or by `expand` above if the root had
        // no traversable subdirectories at all.
        guard let root = rootTask.finishedNode else {
            throw ScanError.rootUnreadable(path: rootPath, errno: EIO)
        }

        if ProcessInfo.processInfo.environment["DISKER_SCAN_STATS"] == "1" {
            let stats = queue.statistics
            let line =
                "  workers \(options.workerCount), directories \(stats.processed), "
                + "peak queue depth \(stats.peakDepth)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }

        return ScanResult(
            root: root,
            rootPath: rootPath,
            duration: Date().timeIntervalSince(started),
            inaccessibleCount: root.inaccessibleCount,
            deduplicatedBytes: context.registry.deduplicatedBytes
        )
    }

    /// Emits `OPEN`/`DONE` around every directory read when `DISKER_TRACE_OPENS=1`.
    ///
    /// Pairing the two is the point: a scan that appears hung is nearly always blocked in
    /// `open(2)` on a handful of directories, and the paths with an `OPEN` and no matching
    /// `DONE` name them exactly. That is how a stall was traced to directories which take a
    /// flat ~21 seconds each to open for any process lacking Full Disk Access — every worker
    /// sat in the kernel while the app looked frozen and burned no CPU at all.
    private static let tracesOpens =
        ProcessInfo.processInfo.environment["DISKER_TRACE_OPENS"] == "1"

    /// Reports each unreadable directory and why, when `DISKER_SCAN_STATS=1`.
    private static let reportsFailures =
        ProcessInfo.processInfo.environment["DISKER_SCAN_STATS"] == "1"

    /// Reads one directory and hands its contents back to the queue.
    private static func process(task: DirectoryTask, context: ScanContext) {
        var entries: [BulkEntry] = []
        if tracesOpens {
            FileHandle.standardError.write(Data("OPEN \(task.path)\n".utf8))
        }
        // Function-scoped so it still fires on the failure path, which is where a stalled
        // directory eventually lands.
        defer {
            if tracesOpens {
                FileHandle.standardError.write(Data("DONE \(task.path)\n".utf8))
            }
        }
        do {
            try BulkDirectoryReader.read(path: task.path) { entries.append($0) }
        } catch {
            // Almost always a missing Full Disk Access grant. Record it and keep going —
            // a partial map with an honest warning beats aborting the whole scan.
            if reportsFailures {
                var code: Int32 = 0
                if case BulkDirectoryReader.ReadError.cannotOpen(let number) = error {
                    code = number
                }
                let reason = String(cString: strerror(code))
                FileHandle.standardError.write(
                    Data("  UNREADABLE errno=\(code) \(reason) \(task.path)\n".utf8))
            }
            context.queue.finishExpansion(
                of: task, leaves: [], subdirectories: [], flags: .inaccessible, context: context)
            return
        }
        expand(task: task, entries: entries, context: context)
    }

    /// Turns a directory's entries into finished leaf nodes plus child tasks to traverse.
    ///
    /// Reading happens outside every lock; only the short handover at the end takes one.
    private static func expand(
        task: DirectoryTask, entries: [BulkEntry], context: ScanContext
    ) {
        var leaves: [FileNode] = []
        leaves.reserveCapacity(entries.count)
        var subdirectories: [DirectoryTask] = []
        var directFileCount = 0
        var directBytes: UInt64 = 0

        for entry in entries {
            guard entry.isDirectory else {
                if let node = leafNode(for: entry, context: context) {
                    leaves.append(node)
                    directFileCount += 1
                    directBytes &+= node.size
                }
                continue
            }

            let childPath =
                task.path == "/" ? "/\(entry.name)" : "\(task.path)/\(entry.name)"
            if context.options.excludedPaths.contains(childPath) { continue }

            // A firmlink or mount point. Descending would either double-count (every
            // firmlink under `/` mirrors content that also lives on the data volume) or
            // stall on a remote share. Reported as a zero-size node so the location stays
            // visible.
            if context.boundaries.isBoundary(childPath) {
                leaves.append(
                    FileNode(
                        name: entry.name, size: 0, kind: .directory,
                        flags: .crossedDevice, fileCount: 0))
                continue
            }

            subdirectories.append(
                DirectoryTask(
                    name: entry.name, path: childPath,
                    accessTime: entry.accessTime, parent: task))
        }

        context.reporter.record(files: directFileCount, bytes: directBytes, path: task.path)
        context.queue.finishExpansion(
            of: task, leaves: leaves, subdirectories: subdirectories, flags: [],
            context: context)
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
    let queue: TraversalQueue
}

/// One directory awaiting traversal, and the partial node being assembled for it.
///
/// Every field is mutated only under `TraversalQueue`'s lock, which is why this is a bare
/// class with no synchronisation of its own — two locks over the same data would be a
/// deadlock waiting to happen, and the critical sections are far shorter than the directory
/// read they sit between.
private final class DirectoryTask: @unchecked Sendable {
    let name: String
    let path: String
    let accessTime: Date?
    let parent: DirectoryTask?

    /// Finished children: leaf nodes from this directory, plus each subdirectory's node as
    /// it completes. Order is not meaningful — `FileNode.directory` sorts by size.
    var children: [FileNode] = []
    /// Subdirectories pushed but not yet finished. The node is built when this reaches zero.
    var outstanding = 0
    /// Whether this directory's own entries have been read, so a task with no subdirectories
    /// is not mistaken for one whose children have all completed already.
    var expanded = false
    var flags: FileNode.Flags = []
    var finishedNode: FileNode?

    init(name: String, path: String, accessTime: Date?, parent: DirectoryTask?) {
        self.name = name
        self.path = path
        self.accessTime = accessTime
        self.parent = parent
    }
}

/// A shared stack of directories and the pool of workers that drains it.
///
/// A stack rather than a queue: taking the most recently discovered directory keeps a worker
/// near the subtree it just read, which is both better for locality and much cheaper in
/// memory, since a breadth-first order would hold every directory of a level at once.
///
/// Balance comes for free. A worker that finishes a small subtree immediately takes more
/// work from the stack, so the lopsidedness that defeats per-level fan-out — one subtree
/// holding two thirds of the disk — costs nothing here.
private final class TraversalQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [DirectoryTask] = []
    private var complete = false
    private var processed = 0
    private var peakDepth = 0

    /// Runs `body` on `workerCount` threads until the root directory has been assembled.
    func run(workerCount: Int, body: @escaping @Sendable (DirectoryTask) -> Void) {
        condition.lock()
        let alreadyDone = complete
        condition.unlock()
        guard !alreadyDone else { return }

        let group = DispatchGroup()
        for _ in 0..<max(1, workerCount) {
            DispatchQueue.global(qos: .userInitiated).async(group: group) { [self] in
                while let task = nextTask() { body(task) }
            }
        }
        group.wait()
    }

    /// Blocks until work is available, or returns nil once the whole tree is assembled.
    ///
    /// An empty stack is not a termination condition: another worker may still be reading a
    /// directory that is about to push more. Only the root's completion ends the run.
    private func nextTask() -> DirectoryTask? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if complete { return nil }
            if let task = stack.popLast() {
                processed += 1
                return task
            }
            condition.wait()
        }
    }

    /// Records a directory's contents, queues its subdirectories, and finalises whatever
    /// that completes — possibly cascading all the way to the root.
    func finishExpansion(
        of task: DirectoryTask,
        leaves: [FileNode],
        subdirectories: [DirectoryTask],
        flags: FileNode.Flags,
        context: ScanContext
    ) {
        condition.lock()
        defer { condition.unlock() }

        task.children.append(contentsOf: leaves)
        task.flags = flags
        task.expanded = true
        task.outstanding += subdirectories.count

        if !subdirectories.isEmpty {
            stack.append(contentsOf: subdirectories)
            peakDepth = max(peakDepth, stack.count)
            condition.broadcast()
        }

        finalizeChain(from: task, options: context.options)
    }

    /// Walks upward building finished nodes while each parent's last child is done.
    ///
    /// Iterative rather than recursive: the chain is as deep as the directory tree, and a
    /// deeply nested path should not risk the stack.
    private func finalizeChain(from start: DirectoryTask, options: ScanOptions) {
        var current: DirectoryTask? = start
        while let task = current,
            task.expanded, task.outstanding == 0, task.finishedNode == nil
        {
            let node = FileNode.directory(
                name: task.name,
                rawChildren: task.children,
                options: options,
                flags: task.flags,
                accessTime: task.accessTime
            )
            task.finishedNode = node
            // Release the children now the node owns them; on a full-volume scan this is
            // millions of nodes that would otherwise be retained twice until the scan ends.
            task.children = []

            guard let parent = task.parent else {
                complete = true
                condition.broadcast()
                return
            }
            parent.children.append(node)
            parent.outstanding -= 1
            current = parent
        }
    }

    var statistics: (processed: Int, peakDepth: Int) {
        condition.lock()
        defer { condition.unlock() }
        return (processed, peakDepth)
    }
}
