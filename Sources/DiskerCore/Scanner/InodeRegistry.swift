import Foundation

/// Tracks inodes already counted, so hardlinks and APFS clones are charged exactly once.
///
/// Without this, a Time Machine local snapshot or a cloned VM image can appear to occupy
/// several times the space it really does, and the reported total exceeds the size of the disk.
///
/// Only entries with `linkCount > 1` are registered. Single-linked files — the overwhelming
/// majority — never touch the lock, keeping contention negligible even with several workers.
///
/// Which path "owns" a shared inode depends on traversal order and is therefore not
/// deterministic between runs. The total is unaffected; only the attribution of shared bytes
/// to one sibling rather than another can shift.
final class InodeRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let device: Int32
        let fileID: UInt64
    }

    private var claimed: Set<Key> = []
    private var deduplicated: UInt64 = 0
    private let lock = NSLock()

    /// Returns `true` if the caller should count `size`, `false` if another path already has.
    func claim(device: Int32, fileID: UInt64, size: UInt64) -> Bool {
        let key = Key(device: device, fileID: fileID)
        lock.lock()
        defer { lock.unlock() }
        if claimed.insert(key).inserted {
            return true
        }
        deduplicated &+= size
        return false
    }

    var deduplicatedBytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return deduplicated
    }
}

/// Aggregates live counters and throttles progress callbacks.
///
/// Reporting every file would flood the UI with far more updates than a display can show;
/// emitting on a byte/file interval keeps the status line lively without the scan paying
/// for it.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: UInt64 = 0
    private var lastReportedFiles = 0
    private let emit: @Sendable (ScanProgress) -> Void
    private let interval: Int

    init(interval: Int = 2000, emit: @escaping @Sendable (ScanProgress) -> Void) {
        self.interval = interval
        self.emit = emit
    }

    func record(files newFiles: Int, bytes newBytes: UInt64, path: String) {
        var snapshot: ScanProgress?
        lock.lock()
        files += newFiles
        bytes &+= newBytes
        if files - lastReportedFiles >= interval {
            lastReportedFiles = files
            snapshot = ScanProgress(filesScanned: files, bytesScanned: bytes, currentPath: path)
        }
        lock.unlock()

        // Emitted outside the lock: the callback hops to the main actor, and holding a
        // lock across that would serialise every worker behind the UI.
        if let snapshot { emit(snapshot) }
    }

    var totals: (files: Int, bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (files, bytes)
    }
}
