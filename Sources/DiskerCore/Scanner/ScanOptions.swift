import Foundation

public struct ScanOptions: Sendable {
    /// Files smaller than this are folded into an aggregate node rather than retained
    /// individually. 1 MB keeps a full-volume tree to a manageable size while preserving
    /// every file large enough to be worth acting on.
    public var smallFileThreshold: UInt64

    /// Upper bound on retained children per directory. Guards against pathological
    /// directories (caches with 100k entries) blowing up memory and the chart alike.
    public var maxChildrenPerDirectory: Int

    /// Threads traversing directories.
    ///
    /// An earlier comment here claimed traversal was I/O-bound and that concurrency cost
    /// more in APFS contention than it gained, which is why the value was set low. It was
    /// also dead — declared, defaulted, and never read, because traversal fanned out only
    /// at the root and took whatever width libdispatch chose.
    ///
    /// Measurement says the opposite. Traversal is bound by syscall *latency*, so threads
    /// spend most of their time blocked and oversubscribing the cores is the right move. A
    /// full scan of a 204 GB volume went 49.6s on one thread, 13.5s on four, and ~9s from
    /// eight upward; past about twenty it turns back down as contention takes over.
    ///
    /// Hence twice the core count, capped: the cap keeps a many-core machine off the far
    /// side of that curve, and the floor keeps a small one from crawling.
    public var workerCount: Int

    /// Stay on the volume we started on. Without this, scanning `/` follows the
    /// `/System/Volumes/Data` firmlink and reports roughly double the real usage.
    public var stayOnDevice: Bool

    /// Directories never descended into. These are either synthetic, volatile, or
    /// separately accounted for, and traversing them yields misleading numbers.
    public var excludedPaths: Set<String>

    public init(
        smallFileThreshold: UInt64 = 1024 * 1024,
        maxChildrenPerDirectory: Int = 256,
        workerCount: Int = min(16, max(4, ProcessInfo.processInfo.activeProcessorCount * 2)),
        stayOnDevice: Bool = true,
        excludedPaths: Set<String> = ScanOptions.defaultExclusions
    ) {
        self.smallFileThreshold = smallFileThreshold
        self.maxChildrenPerDirectory = maxChildrenPerDirectory
        self.workerCount = workerCount
        self.stayOnDevice = stayOnDevice
        self.excludedPaths = excludedPaths
    }

    public static let defaultExclusions: Set<String> = [
        "/dev",
        "/net",
        "/home",
        "/Volumes",
        "/System/Volumes/VM",          // swap; transient and not user-reclaimable
        "/System/Volumes/Preboot",
        "/System/Volumes/Recovery",
        "/System/Volumes/Update",
        "/.Spotlight-V100",
        "/.fseventsd",
        "/.DocumentRevisions-V100",
        "/.MobileBackups",             // Time Machine local snapshots; reported separately
    ]
}

/// Incremental scan progress, delivered as an `AsyncStream` so the UI can show live
/// counts without the scanner knowing anything about SwiftUI.
public struct ScanProgress: Sendable {
    public let filesScanned: Int
    public let bytesScanned: UInt64
    /// Most recent directory visited — shown as the scrolling status line.
    public let currentPath: String

    public init(filesScanned: Int, bytesScanned: UInt64, currentPath: String) {
        self.filesScanned = filesScanned
        self.bytesScanned = bytesScanned
        self.currentPath = currentPath
    }
}

public struct ScanResult: Sendable {
    public let root: FileNode
    public let rootPath: String
    public let duration: TimeInterval
    /// Directories that could not be read. Non-zero almost always means Full Disk Access
    /// is missing, and means the reported total is a lower bound.
    public let inaccessibleCount: Int
    /// Bytes not counted because another path already claimed the same inode.
    public let deduplicatedBytes: UInt64

    public init(
        root: FileNode,
        rootPath: String,
        duration: TimeInterval,
        inaccessibleCount: Int,
        deduplicatedBytes: UInt64
    ) {
        self.root = root
        self.rootPath = rootPath
        self.duration = duration
        self.inaccessibleCount = inaccessibleCount
        self.deduplicatedBytes = deduplicatedBytes
    }
}
