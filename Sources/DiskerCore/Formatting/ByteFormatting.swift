import Foundation

extension UInt64 {
    /// Decimal units, matching Finder and Mole. A user comparing Disker's numbers against
    /// "Get Info" should see the same figure, so binary units would be the wrong choice
    /// regardless of which is technically more accurate.
    public var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: self))
    }
}

/// Live capacity figures for a mounted volume.
public struct VolumeInfo: Sendable {
    public let name: String
    public let path: String
    public let totalCapacity: UInt64
    /// Space genuinely available, after macOS deducts what it will not evict for you.
    public let availableCapacity: UInt64
    /// Space currently occupied by caches and snapshots that macOS will reclaim on demand.
    /// Reported separately because presenting it as free is how "you have 90 GB free"
    /// turns into a failed download.
    public let purgeableCapacity: UInt64

    public var usedCapacity: UInt64 {
        totalCapacity > availableCapacity ? totalCapacity - availableCapacity : 0
    }

    public var usedFraction: Double {
        totalCapacity == 0 ? 0 : Double(usedCapacity) / Double(totalCapacity)
    }

    public init(
        name: String, path: String, totalCapacity: UInt64,
        availableCapacity: UInt64, purgeableCapacity: UInt64
    ) {
        self.name = name
        self.path = path
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.purgeableCapacity = purgeableCapacity
    }

    public static func current(for path: String = "/System/Volumes/Data") -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let total = UInt64(values.volumeTotalCapacity ?? 0)
        // `forImportantUsage` is the honest figure: it counts space macOS would free by
        // evicting purgeable content. `volumeAvailableCapacity` is the pessimistic one.
        let important = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let plain = UInt64(values.volumeAvailableCapacity ?? 0)

        return VolumeInfo(
            name: values.volumeName ?? "Macintosh HD",
            path: path,
            totalCapacity: total,
            availableCapacity: plain,
            purgeableCapacity: important > plain ? important - plain : 0
        )
    }
}
