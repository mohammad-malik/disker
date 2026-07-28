import Foundation

/// A mounted volume the user can choose to analyse.
public struct Volume: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let totalCapacity: UInt64
    public let availableCapacity: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool

    public var usedCapacity: UInt64 {
        totalCapacity > availableCapacity ? totalCapacity - availableCapacity : 0
    }

    public var symbolName: String {
        if isRemovable { return "externaldrive" }
        return isInternal ? "internaldrive" : "externaldrive.connected.to.line.below"
    }
}

/// Lists volumes worth offering in the disk picker.
public enum VolumeCatalog {

    /// Mount points that are real volumes but never useful to analyse — either synthetic,
    /// or already represented by the data volume the app scans by default.
    private static let hiddenMountPoints: Set<String> = [
        "/System/Volumes/VM",
        "/System/Volumes/Preboot",
        "/System/Volumes/Update",
        "/System/Volumes/xarts",
        "/System/Volumes/iSCPreboot",
        "/System/Volumes/Hardware",
        "/System/Volumes/Recovery",
    ]

    public static func mountedVolumes() -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsBrowsableKey,
            .volumeIsLocalKey,
        ]

        guard
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes])
        else { return [] }

        var volumes: [Volume] = []
        for url in urls {
            let path = url.path
            if hiddenMountPoints.contains(path) { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            // Network shares are excluded: walking one over the wire takes hours and the
            // numbers say nothing about local disk pressure.
            guard values.volumeIsLocal ?? true else { continue }
            guard values.volumeIsBrowsable ?? true else { continue }

            let capacity = UInt64(values.volumeTotalCapacity ?? 0)
            guard capacity > 0 else { continue }

            // The root volume is offered as its data volume: `/` is the sealed system
            // snapshot, ~12 GB of OS the user can neither browse nor reclaim, so scanning
            // it instead of their files would be actively unhelpful.
            let isRoot = path == "/"
            let scanPath = isRoot ? "/System/Volumes/Data" : path

            volumes.append(
                Volume(
                    name: values.volumeName ?? url.lastPathComponent,
                    path: scanPath,
                    totalCapacity: capacity,
                    availableCapacity: UInt64(values.volumeAvailableCapacity ?? 0),
                    isInternal: values.volumeIsInternal ?? isRoot,
                    isRemovable: values.volumeIsRemovable ?? false))
        }

        // Internal disks first, then by size — the boot volume is what people came to look at.
        return volumes.sorted {
            $0.isInternal == $1.isInternal
                ? $0.totalCapacity > $1.totalCapacity
                : $0.isInternal && !$1.isInternal
        }
    }

    /// The volume Disker opens on.
    public static func defaultVolume() -> Volume? {
        mountedVolumes().first { $0.path == "/System/Volumes/Data" }
            ?? mountedVolumes().first
    }
}
