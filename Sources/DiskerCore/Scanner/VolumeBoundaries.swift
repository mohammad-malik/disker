import Foundation

/// Paths where traversal must stop because continuing would leave the volume being scanned.
///
/// The obvious approach — compare `st_dev` against the root's, the classic Unix `du -x`
/// technique — **does not work on modern macOS**. In an APFS volume group the sealed system
/// volume and the writable data volume report the *same* device ID:
///
///     stat -f %d /                    → 16777234
///     stat -f %d /System/Volumes/Data → 16777234
///
/// even though `df` shows them as `/dev/disk3s1s1` and `/dev/disk3s5`. Relying on `st_dev`
/// therefore lets a scan of `/` follow the `/Users` firmlink into the data volume and count
/// every user file a second time, roughly doubling the reported total.
///
/// Two sources give an exact answer instead:
///
///   * `/usr/share/firmlinks` — the table macOS itself uses to graft data-volume directories
///     onto the system volume (`/Users`, `/Applications`, `/opt`, `/private`, …).
///   * `getmntinfo(3)` — every real mount point, covering external drives, disk images,
///     and network shares.
///
/// Both are small, read once, and checked with an O(1) set lookup, so this costs nothing
/// per directory.
public struct VolumeBoundaries: Sendable {
    private let boundaries: Set<String>

    /// The volume a path actually belongs to, as `statfs` reports it (e.g. `/dev/disk3s5`).
    /// Unlike `st_dev` this does distinguish the volumes in a volume group.
    public static func volumeDevice(of path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_mntfromname) { raw in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    public init(scanRoot: String) {
        var paths = Set<String>()

        // Firmlinked directories are the data volume showing through the system volume.
        // Only a scan rooted on the system volume can reach them this way; a scan rooted at
        // /System/Volumes/Data reaches the same files by their real path, where they must
        // still be counted.
        let rootDevice = Self.volumeDevice(of: scanRoot)
        let systemDevice = Self.volumeDevice(of: "/")
        if rootDevice == systemDevice,
            let table = try? String(contentsOfFile: "/usr/share/firmlinks", encoding: .utf8)
        {
            for line in table.split(separator: "\n") {
                // Format: "<path-on-system-volume>\t<path-on-data-volume>"
                if let path = line.split(separator: "\t").first {
                    paths.insert(String(path))
                }
            }
        }

        // Every mount point other than the scan root itself. Descending into these would
        // either double-count (nested volumes) or block on a slow network share.
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        if count > 0, let buffer {
            for index in 0..<Int(count) {
                var entry = buffer[index]
                let mountPoint = withUnsafeBytes(of: &entry.f_mntonname) { raw -> String in
                    guard let base = raw.baseAddress else { return "" }
                    return String(cString: base.assumingMemoryBound(to: CChar.self))
                }
                if !mountPoint.isEmpty, mountPoint != "/", mountPoint != scanRoot {
                    paths.insert(mountPoint)
                }
            }
        }

        boundaries = paths
    }

    /// Test-only initialiser.
    init(explicit: Set<String>) {
        boundaries = explicit
    }

    public func isBoundary(_ path: String) -> Bool {
        boundaries.contains(path)
    }

    public var all: Set<String> { boundaries }
}
