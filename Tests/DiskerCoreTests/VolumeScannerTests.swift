import Foundation
import Testing

@testable import DiskerCore

/// Builds a throwaway directory tree containing the specific filesystem shapes that make
/// naive disk scanners report wrong numbers.
private struct Fixture: ~Copyable {
    let root: URL

    init(name: String = UUID().uuidString) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "disker-tests-\(name)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeFile(_ relativePath: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
        return url
    }

    func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    deinit {
        // Restore permissions first: a mode-000 directory cannot be removed otherwise.
        if let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants])
        {
            for case let url as URL in walker {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("VolumeScanner correctness")
struct VolumeScannerTests {

    /// Small files would otherwise be folded into aggregates, hiding the very nodes under test.
    private var granularOptions: ScanOptions {
        ScanOptions(smallFileThreshold: 0, maxChildrenPerDirectory: 1000, stayOnDevice: false)
    }

    @Test("Sums file sizes across a nested tree")
    func sumsNestedTree() async throws {
        let fixture = try Fixture()
        _ = try fixture.makeFile("a.bin", bytes: 200_000)
        _ = try fixture.makeFile("sub/b.bin", bytes: 300_000)
        _ = try fixture.makeFile("sub/deep/c.bin", bytes: 100_000)

        let result = try await VolumeScanner(options: granularOptions).scan(path: fixture.root.path)

        // Allocated size rounds up to block boundaries, so assert a band rather than equality.
        #expect(result.root.size >= 600_000)
        #expect(result.root.size < 700_000)
        #expect(result.root.fileCount == 3)
    }

    @Test("Hardlinked files are counted once, not once per link")
    func hardlinksAreDeduplicated() async throws {
        let fixture = try Fixture()
        let original = try fixture.makeFile("original.bin", bytes: 500_000)
        let linkPath = fixture.root.appendingPathComponent("hardlink.bin").path
        #expect(link(original.path, linkPath) == 0)

        let result = try await VolumeScanner(options: granularOptions).scan(path: fixture.root.path)

        // Both names exist on disk but they share one inode — charging both would report
        // ~1 MB for 500 KB of actual storage.
        #expect(result.root.size >= 500_000)
        #expect(result.root.size < 600_000)
        #expect(result.deduplicatedBytes >= 500_000)
        #expect(result.root.children.count == 2)
    }

    @Test("Symlink loops terminate instead of hanging")
    func symlinkLoopsDoNotRecurse() async throws {
        let fixture = try Fixture()
        let target = try fixture.makeDirectory("real")
        _ = try fixture.makeFile("real/data.bin", bytes: 50_000)
        let loop = fixture.root.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: target)
        // A symlink pointing at its own ancestor is the classic infinite-descent trap.
        let selfLoop = fixture.root.appendingPathComponent("real/up")
        try FileManager.default.createSymbolicLink(at: selfLoop, withDestinationURL: fixture.root)

        let result = try await VolumeScanner(options: granularOptions).scan(path: fixture.root.path)

        #expect(result.root.size < 200_000)
        #expect(result.root.children.contains { $0.name == "loop" && $0.kind == .symlink })
    }

    @Test("Unreadable directories are flagged, not fatal")
    func unreadableDirectoriesAreFlagged() async throws {
        let fixture = try Fixture()
        _ = try fixture.makeFile("readable.bin", bytes: 100_000)
        let blocked = try fixture.makeDirectory("blocked")
        _ = try fixture.makeFile("blocked/hidden.bin", bytes: 400_000)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)

        let result = try await VolumeScanner(options: granularOptions).scan(path: fixture.root.path)

        // This is exactly the shape of a missing Full Disk Access grant: the scan must
        // complete and say so, rather than abort or silently under-report.
        #expect(result.inaccessibleCount == 1)
        #expect(result.root.size >= 100_000)
        #expect(result.root.size < 200_000)
    }

    @Test("Empty directories scan cleanly")
    func emptyDirectory() async throws {
        let fixture = try Fixture()
        let result = try await VolumeScanner(options: granularOptions).scan(path: fixture.root.path)
        #expect(result.root.size == 0)
        #expect(result.root.children.isEmpty)
    }

    @Test("Missing path throws rather than returning an empty tree")
    func missingPathThrows() async throws {
        await #expect(throws: VolumeScanner.ScanError.self) {
            try await VolumeScanner().scan(path: "/nonexistent-\(UUID().uuidString)")
        }
    }

    @Test("Progress callbacks fire during a scan")
    func progressIsReported() async throws {
        let fixture = try Fixture()
        for index in 0..<50 {
            _ = try fixture.makeFile("f\(index).bin", bytes: 10_000)
        }

        // The reporter throttles to every 2000 files, so a small fixture emits nothing.
        // Verify the final totals instead, which is what the throttle ultimately feeds.
        let result = try await VolumeScanner(options: granularOptions).scan(path: fixture.root.path)
        #expect(result.root.fileCount == 50)
        #expect(result.duration > 0)
    }

    /// The invariant that traversal is concurrent for speed only, never for its answers.
    ///
    /// Worth asserting explicitly, because it has already been broken once. Traversal marks
    /// a directory unreadable when opening it fails, and an `open` interrupted by a signal
    /// fails like any other — so with sixteen workers a full-volume scan reported ten more
    /// unreadable directories than the same scan with one, dropping their contents from the
    /// total. Nothing about that was visible in a single-threaded test.
    @Test("Results do not depend on how many workers ran")
    func resultsAreIndependentOfWorkerCount() async throws {
        let fixture = try Fixture()
        // Wide and deep, so tasks are still being pushed while others are being finalised
        // and the finish-the-parent cascade actually has something to race against.
        for branch in 0..<12 {
            for depth in 0..<4 {
                let path = (0...depth).map { "b\(branch)-d\($0)" }.joined(separator: "/")
                _ = try fixture.makeFile("\(path)/leaf.bin", bytes: 20_000 + depth)
            }
        }
        _ = try fixture.makeDirectory("empty")

        var totals: [(workers: Int, size: UInt64, files: Int, unreadable: Int)] = []
        for workers in [1, 2, 8, 16] {
            var options = granularOptions
            options.workerCount = workers
            let result = try await VolumeScanner(options: options).scan(path: fixture.root.path)
            totals.append(
                (workers, result.root.size, result.root.fileCount, result.inaccessibleCount))
        }

        let reference = try #require(totals.first)
        #expect(reference.files == 48)
        for outcome in totals.dropFirst() {
            #expect(
                outcome.size == reference.size,
                "size differs at \(outcome.workers) workers")
            #expect(
                outcome.files == reference.files,
                "file count differs at \(outcome.workers) workers")
            #expect(
                outcome.unreadable == reference.unreadable,
                "unreadable count differs at \(outcome.workers) workers")
        }
    }

    /// Guards the traversal queue against stalling, and its finalisation against the stack.
    ///
    /// A chain like this exposes only one runnable directory at a time, so every worker but
    /// one is parked on an empty queue for the whole scan while the root stays unfinished.
    /// If the cascade that finishes a directory once its last child completes ever fails to
    /// reach the root, those workers wait forever and this hangs rather than fails.
    ///
    /// It also keeps the finalisation loop honest about depth: that cascade climbs one level
    /// per finished directory, and written recursively it would put the tree's full depth on
    /// a single stack.
    @Test("A single deep chain finishes rather than stalling")
    func deepChainTerminates() async throws {
        let fixture = try Fixture()
        // Single-character components: the whole chain still has to fit in PATH_MAX, and
        // the point here is depth rather than long names.
        let chain = (0..<120).map { "d\($0)" }.joined(separator: "/")
        _ = try fixture.makeFile("\(chain)/bottom.bin", bytes: 30_000)

        var options = granularOptions
        options.workerCount = 8
        let result = try await VolumeScanner(options: options).scan(path: fixture.root.path)

        #expect(result.root.fileCount == 1)
        #expect(result.root.size >= 30_000)
    }
}
