import Foundation
import Testing

@testable import DiskerCore

@Suite("Scan cache")
struct ScanCacheTests {

    /// Each test gets its own throwaway directory. Pointing these at the real Application
    /// Support location would make running the suite delete the user's cached scan.
    private func makeCache() -> (cache: ScanCache, cleanup: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disker-cache-\(UUID().uuidString)")
        return (
            ScanCache(directory: directory),
            { try? FileManager.default.removeItem(at: directory) }
        )
    }

    private func sampleResult(rootPath: String = "/System/Volumes/Data") -> ScanResult {
        let tree = FileNode(
            name: "Data", size: 3000, kind: .directory,
            children: [
                FileNode(
                    name: "Users", size: 2000, kind: .directory,
                    children: [FileNode(name: "big.bin", size: 2000, kind: .file)],
                    fileCount: 1),
                FileNode(name: "loose.bin", size: 1000, kind: .file, flags: .deduplicated),
            ],
            fileCount: 2)
        return ScanResult(
            root: tree, rootPath: rootPath, duration: 12.5,
            inaccessibleCount: 7, deduplicatedBytes: 900)
    }

    @Test("A saved scan round-trips with its tree and metadata intact")
    func roundTrip() throws {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        let original = sampleResult()
        cache.save(original)

        let entry = try #require(cache.load(expecting: original.rootPath))
        let restored = entry.result

        #expect(restored.root.size == original.root.size)
        #expect(restored.root.fileCount == original.root.fileCount)
        #expect(restored.rootPath == original.rootPath)
        // Both caveats drive on-screen warnings, so losing them would make a restored scan
        // look cleaner than the one that was actually run.
        #expect(restored.inaccessibleCount == 7)
        #expect(restored.deduplicatedBytes == 900)

        // Structure and flags must survive, not just the top-level totals.
        #expect(restored.root.children.count == 2)
        let users = try #require(restored.root.children.first { $0.name == "Users" })
        #expect(users.children.first?.name == "big.bin")
        let loose = try #require(restored.root.children.first { $0.name == "loose.bin" })
        #expect(loose.flags.contains(.deduplicated))
    }

    @Test("A cache for a different volume is ignored")
    func rejectsMismatchedRoot() {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(sampleResult(rootPath: "/Volumes/External"))

        // Showing an external drive's tree under the internal disk's name would be worse
        // than showing nothing at all.
        #expect(cache.load(expecting: "/System/Volumes/Data") == nil)
    }

    @Test("Missing cache reports nothing rather than failing")
    func missingCacheIsNotAnError() {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        #expect(cache.load(expecting: "/System/Volumes/Data") == nil)
    }

    @Test("Corrupt cache is discarded instead of crashing")
    func corruptCacheIsDiscarded() throws {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(sampleResult())

        // Simulates a tree written by an older build whose shape no longer decodes.
        let url = try #require(cache.storageURL)
        try Data("not a property list".utf8).write(to: url)

        #expect(cache.load(expecting: "/System/Volumes/Data") == nil)
        // The unusable file should be cleared so it cannot fail again on every launch.
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Deeply nested trees survive encoding")
    func deepTreeRoundTrips() throws {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        // Real scans nest well past this; a recursion limit in the encoder would show here.
        var node = FileNode(name: "leaf", size: 100, kind: .file)
        for level in 0..<64 {
            node = FileNode(
                name: "level\(level)", size: 100, kind: .directory,
                children: [node], fileCount: 1)
        }
        let root = FileNode(
            name: "Data", size: 100, kind: .directory, children: [node], fileCount: 1)

        cache.save(
            ScanResult(
                root: root, rootPath: "/System/Volumes/Data", duration: 1,
                inaccessibleCount: 0, deduplicatedBytes: 0))

        let entry = try #require(cache.load(expecting: "/System/Volumes/Data"))
        var depth = 0
        var cursor: FileNode? = entry.result.root
        while let current = cursor {
            depth += 1
            cursor = current.children.first
        }
        #expect(depth == 66)
    }
}
