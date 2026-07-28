import Foundation
import Testing

@testable import DiskerCore

/// Regression cover for the firmlink double-counting bug.
///
/// The first implementation used the conventional `st_dev` comparison (`du -x`'s technique).
/// On this machine that made a scan of `/` report 427 GB on a 228 GB disk, because APFS
/// volume groups give the system and data volumes an identical device ID and the scan
/// followed `/Users` straight back into the data volume.
@Suite("Volume boundaries")
struct VolumeBoundaryTests {

    @Test("System and data volumes are indistinguishable by st_dev")
    func stDevCannotSeparateVolumeGroupMembers() throws {
        // Documents *why* the boundary logic cannot be the obvious one. If a future macOS
        // starts reporting distinct device IDs this test fails loudly, and the simpler
        // approach becomes available again.
        var systemStat = stat()
        var dataStat = stat()
        try #require(lstat("/", &systemStat) == 0)
        try #require(lstat("/System/Volumes/Data", &dataStat) == 0)

        #expect(systemStat.st_dev == dataStat.st_dev)
    }

    @Test("statfs does separate them")
    func statfsSeparatesVolumeGroupMembers() throws {
        let system = try #require(VolumeBoundaries.volumeDevice(of: "/"))
        let data = try #require(VolumeBoundaries.volumeDevice(of: "/System/Volumes/Data"))

        #expect(system != data)
    }

    @Test("Firmlinked directories are boundaries when scanning the system volume")
    func firmlinksAreBoundariesFromSystemRoot() {
        let boundaries = VolumeBoundaries(scanRoot: "/")

        // These live on the data volume and merely show through onto the system volume.
        // Counting them during a scan of `/` is the double-count.
        #expect(boundaries.isBoundary("/Users"))
        #expect(boundaries.isBoundary("/Applications"))
        #expect(boundaries.isBoundary("/private"))
        #expect(boundaries.isBoundary("/opt"))
    }

    @Test("Firmlink paths are not boundaries when scanning the data volume")
    func firmlinksAreNotBoundariesFromDataRoot() {
        let boundaries = VolumeBoundaries(scanRoot: "/System/Volumes/Data")

        // Reached by their real paths here, so they must be counted — otherwise a data
        // volume scan would omit the user's entire home directory.
        #expect(!boundaries.isBoundary("/System/Volumes/Data/Users"))
        #expect(!boundaries.isBoundary("/Users"))
    }

    @Test("The scan root is never treated as its own boundary")
    func scanRootIsNotABoundary() {
        // /System/Volumes/Data appears in the mount table; excluding it would make a scan
        // rooted there return nothing at all.
        let boundaries = VolumeBoundaries(scanRoot: "/System/Volumes/Data")
        #expect(!boundaries.isBoundary("/System/Volumes/Data"))
    }

    @Test("Scanning the system volume stays within its real capacity")
    func systemVolumeScanIsPlausible() async throws {
        let result = try await VolumeScanner().scan(path: "/")

        var info = statfs()
        try #require(statfs("/", &info) == 0)
        let capacity = UInt64(info.f_blocks) * UInt64(info.f_bsize)

        // The end-to-end assertion the old implementation failed: a volume cannot hold
        // more bytes than it has.
        #expect(result.root.size < capacity)
    }
}
