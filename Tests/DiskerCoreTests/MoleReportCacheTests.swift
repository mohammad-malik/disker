import Foundation
import Testing

@testable import DiskerCore

/// Covers the cache that stops `mole clean --dry-run` from running on every launch.
///
/// That command takes about 98 seconds against Mole 1.43.1 — longer than scanning the whole
/// disk — and Mole offers no cheaper way to ask for the same figures, so how often it is run
/// is the only thing that can be tuned.
@Suite("Mole report cache")
struct MoleReportCacheTests {

    /// Each test gets its own throwaway directory, for the same reason `ScanCache`'s tests
    /// do: pointing these at Application Support would trample the real cached preview.
    private func makeCache() -> (cache: MoleReportCache, cleanup: () -> Void) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disker-mole-\(UUID().uuidString)")
        return (
            MoleReportCache(directory: directory),
            { try? FileManager.default.removeItem(at: directory) }
        )
    }

    private var sampleReport: MoleReport {
        .parsed(
            categories: [
                MoleCategory(
                    name: "Developer",
                    items: [
                        MoleItem(name: "Xcode DerivedData", size: 4_000_000_000),
                        MoleItem(name: "npm cache", size: 1_500_000_000),
                    ]),
                MoleCategory(
                    name: "Caches",
                    items: [MoleItem(name: "User caches", size: 900_000_000)]),
            ],
            totalReclaimable: 6_400_000_000)
    }

    @Test("A saved preview round-trips with its categories and totals intact")
    func roundTrip() throws {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(sampleReport)
        let entry = try #require(cache.load())

        #expect(entry.report.totalReclaimable == 6_400_000_000)
        #expect(entry.report.categories.count == 2)
        #expect(entry.report.categories.first?.name == "Developer")
        #expect(entry.report.categories.first?.items.count == 2)
        #expect(entry.report.categories.first?.totalSize == 5_500_000_000)
        #expect(!entry.isStale)
    }

    /// An unparseable result says something about Mole's output format, not about the disk.
    /// Caching it would keep "couldn't read Mole's output" on screen for a day after one
    /// transient failure, and would suppress the retry that might well have worked.
    @Test("A failed parse is not cached")
    func failuresAreNotCached() {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(.unparseable(reason: "Mole is not installed."))

        #expect(cache.load() == nil)
    }

    /// A previously good preview must survive a failed one, or a single hiccup would throw
    /// away a perfectly usable answer and force the 98-second run again.
    @Test("A failed parse leaves an existing preview alone")
    func failureDoesNotEvictAGoodEntry() throws {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(sampleReport)
        cache.save(.unparseable(reason: "Mole output changed."))

        let entry = try #require(cache.load())
        #expect(entry.report.totalReclaimable == 6_400_000_000)
    }

    @Test("Age beyond the freshness window counts as stale")
    func stalenessFollowsTheWindow() {
        let window = MoleReportCache.freshnessWindow
        let fresh = MoleReportCache.Entry(
            report: sampleReport, checkedAt: Date().addingTimeInterval(-window / 2))
        let old = MoleReportCache.Entry(
            report: sampleReport, checkedAt: Date().addingTimeInterval(-window - 60))

        #expect(!fresh.isStale)
        #expect(old.isStale)
    }

    @Test("Clearing removes the preview")
    func clearing() {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(sampleReport)
        #expect(cache.load() != nil)
        cache.clear()
        #expect(cache.load() == nil)
    }

    @Test("Missing cache reports nothing rather than failing")
    func missingCache() {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }
        #expect(cache.load() == nil)
    }

    /// Most likely a file written by an older build. Dropping it beats failing, so that one
    /// stale file cannot break every future launch.
    @Test("Corrupt cache is discarded instead of crashing")
    func corruptCache() throws {
        let (cache, cleanup) = makeCache()
        defer { cleanup() }

        cache.save(sampleReport)
        let url = try #require(cache.storageURL)
        try Data("not a property list".utf8).write(to: url)

        #expect(cache.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
