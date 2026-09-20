import Foundation
import Testing

@testable import DiskerCore

@Suite("Rules inside bundles")
struct BundleRuleTests {

    private func file(_ name: String, _ size: UInt64, accessed: Date? = nil) -> FileNode {
        FileNode(name: name, size: size, kind: .file, fileCount: 1, accessTime: accessed)
    }

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(
            name: name, size: children.reduce(0) { $0 + $1.size }, kind: .directory,
            children: children, fileCount: children.reduce(0) { $0 + $1.fileCount })
    }

    private func analyze(_ children: [FileNode]) -> [Recommendation] {
        let root = directory("root", [directory("Users", [directory("tester", children)])])
        return RecommendationEngine.analyze(
            result: ScanResult(
                root: root, rootPath: "/", duration: 0, inaccessibleCount: 0,
                deduplicatedBytes: 0),
            policy: SafetyPolicy(home: "/Users/tester"))
    }

    /// A library holding the two regenerable directories, the footage, and bait for every
    /// generic rule in the engine.
    private var baitedLibrary: FileNode {
        let ancient = Date(timeIntervalSinceNow: -500 * 24 * 3600)
        return directory("Wedding.fcpbundle", [
            directory("Ceremony", [
                directory("Render Files", [file("render.mov", 40_000_000_000)]),
                directory("Analysis Files", [file("analysis.dat", 2_000_000_000)]),
                // The only copy of the footage in an imported-with-copy library.
                directory("Original Media", [file("A001.mov", 80_000_000_000)]),
                directory("Transcoded Media", [file("proxy.mov", 20_000_000_000)]),
                // Bait for the build-artefact rule and the stale-large-file rule.
                directory("node_modules", [file("dep.js", 900_000_000)]),
                file("forgotten.zip", 3_000_000_000, accessed: ancient),
            ])
        ])
    }

    @Test("Only the whitelisted names are ever offered from inside a library")
    func onlyWhitelistedNamesEscapeTheBundle() {
        let found = analyze([directory("Movies", [baitedLibrary])])

        #expect(found.count == 2)
        #expect(found.map(\.title).sorted() == ["Analysis Files in Ceremony", "Render Files in Ceremony"])
    }

    @Test("Nothing else inside a bundle is reachable, by any rule")
    func genericRulesCannotReachInsideABundle() {
        // This is the assertion that has to keep holding as rules are added. The walk does not
        // recurse past a bundle boundary, so a new rule cannot reach this footage even if its
        // author never reads the comment explaining why.
        let paths = analyze([directory("Movies", [baitedLibrary])]).map(\.path)

        #expect(!paths.contains { $0.contains("Original Media") })
        #expect(!paths.contains { $0.contains("Transcoded Media") })
        #expect(!paths.contains { $0.contains("node_modules") })
        #expect(!paths.contains { $0.contains("forgotten.zip") })
    }

    @Test("Render files are review, not safe")
    func renderFilesAreReview() {
        // Regenerating costs no data, which reads like safe. Re-rendering a library of this
        // size costs days.
        #expect(analyze([directory("Movies", [baitedLibrary])]).allSatisfy { $0.tier == .review })
    }

    @Test("Logic offers freeze files and nothing else in the package")
    func logicFreezeFiles() {
        let found = analyze([
            directory("Music", [
                directory("Song.logicx", [
                    directory("Freeze Files", [file("frozen.aif", 900_000_000)]),
                    directory("Audio Files", [file("take1.aif", 4_000_000_000)]),
                    directory("Bounces", [file("master.wav", 1_000_000_000)]),
                    directory("Project File Backups", [file("backup.logicx", 50_000_000)]),
                ])
            ])
        ])

        #expect(found.count == 1)
        #expect(found.first?.title == "Freeze files in Song.logicx")
        #expect(found.first?.tier == .review)
    }

    @Test("Bundles with no rule of their own stay closed")
    func otherBundlesAreUntouched() {
        // A .app or a .photoslibrary has no entry in the switch, so nothing inside is visible.
        let found = analyze([
            directory("Applications", [
                directory("Thing.app", [
                    directory("Contents", [
                        directory("node_modules", [file("dep.js", 2_000_000_000)])
                    ])
                ])
            ]),
            directory("Pictures", [
                directory("Photos Library.photoslibrary", [
                    directory("resources", [file("derivative.jpg", 9_000_000_000)])
                ])
            ]),
        ])

        #expect(found.isEmpty)
    }
}
