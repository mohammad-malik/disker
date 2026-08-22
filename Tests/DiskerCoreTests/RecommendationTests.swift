import Foundation
import Testing

@testable import DiskerCore

@Suite("Recommendations")
struct RecommendationTests {

    private func result(root: FileNode, path: String = "/scan") -> ScanResult {
        ScanResult(
            root: root, rootPath: path, duration: 1,
            inaccessibleCount: 0, deduplicatedBytes: 0)
    }

    private func file(_ name: String, _ size: UInt64, accessed: Date? = nil) -> FileNode {
        FileNode(name: name, size: size, kind: .file, accessTime: accessed)
    }

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(
            name: name,
            size: children.reduce(0) { $0 &+ $1.size },
            kind: .directory,
            children: children,
            fileCount: children.reduce(0) { $0 + $1.fileCount })
    }

    @Test("Build artefact directories are flagged as safe")
    func flagsBuildArtefacts() {
        let tree = directory(
            "Users",
            [
                directory(
                    "alex",
                    [
                        directory(
                            "myapp", [directory("node_modules", [file("big.js", 4_000_000_000)])])
                    ])
            ])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))
        let artefact = found.first { $0.title.contains("node_modules") }

        #expect(artefact != nil)
        #expect(artefact?.tier == .safe)
        #expect(artefact?.size == 4_000_000_000)
        // Names the containing project so several node_modules stay distinguishable.
        #expect(artefact?.title.contains("myapp") == true)
    }

    @Test("Artefact directories are not descended into")
    func doesNotRecurseIntoArtefacts() {
        // A stale 2 GB file inside node_modules must not become its own suggestion —
        // removing the parent already covers it.
        let stale = file("old.bin", 2_000_000_000, accessed: Date(timeIntervalSinceNow: -400 * 24 * 3600))
        let tree = directory("proj", [directory("node_modules", [stale])])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        #expect(found.count == 1)
        #expect(found.first?.title.contains("node_modules") == true)
    }

    @Test("node_modules inside an app bundle is never suggested")
    func doesNotSuggestDeletingInsideAppBundles() {
        // Exactly the shape a real Electron app has on disk. Deleting this node_modules
        // does not reclaim build output — it breaks the installed application.
        let tree = directory(
            "Applications",
            [
                directory(
                    "T3 Code.app",
                    [
                        directory(
                            "Contents",
                            [
                                directory(
                                    "Resources",
                                    [
                                        directory(
                                            "app.asar.unpacked",
                                            [
                                                directory(
                                                    "node_modules",
                                                    [file("index.js", 458_000_000)])
                                            ])
                                    ])
                            ])
                    ])
            ])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        #expect(found.isEmpty)
    }

    @Test("Bundle detection covers the common wrappers")
    func recognisesBundleExtensions() {
        #expect(RecommendationEngine.isBundle("Safari.app"))
        #expect(RecommendationEngine.isBundle("Electron.framework"))
        #expect(RecommendationEngine.isBundle("Widget.appex"))
        #expect(RecommendationEngine.isBundle("Photos.photoslibrary"))
        // A project directory that merely contains a dot must not be mistaken for one.
        #expect(!RecommendationEngine.isBundle("node_modules"))
        #expect(!RecommendationEngine.isBundle("my.project"))
        #expect(!RecommendationEngine.isBundle(".venv"))
    }

    @Test("Real project artifacts are still found outside bundles")
    func stillFindsRealArtifacts() {
        // The bundle guard must not suppress the case the feature exists for.
        let tree = directory(
            "Users",
            [
                directory(
                    "alex",
                    [directory("myapp", [directory("node_modules", [file("a.js", 900_000_000)])])])
            ])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        #expect(found.count == 1)
        #expect(found.first?.tier == .safe)
    }

    @Test("Trash is flagged")
    func flagsTrash() {
        let tree = directory("Users", [directory("alex", [directory(".Trash", [file("junk", 500_000_000)])])])
        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        #expect(found.contains { $0.title == "Empty the Trash" && $0.tier == .safe })
    }

    @Test("The Trash is emptied rather than moved to the Trash")
    func trashIsEmptiedNotMoved() {
        let tree = directory(
            "Users",
            [
                directory("alex", [
                    directory(".Trash", [file("junk", 500_000_000)]),
                    directory("project", [directory("node_modules", [file("dep.js", 900_000_000)])]),
                ])
            ])
        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        // `trashItem` cannot put the Trash inside the Trash, so this row failed every time
        // it was clicked. It carries the one action that is not a move.
        #expect(found.first { $0.title == "Empty the Trash" }?.action == .emptyTrash)
        // And nothing else quietly changed action along with it.
        #expect(found.first { $0.title.hasPrefix("node_modules") }?.action == .moveToTrash)
    }

    @Test("A folder merely named .Trash is never offered for permanent deletion")
    func onlyTheRealTrashIsEmptied() {
        // Position, not name. Emptying is the one action with nothing to recover from, so a
        // fixture directory, a synced folder, or a `.Trash` inside a disk image must not
        // qualify for it on the strength of its name.
        let impostors = directory(
            "Users",
            [
                directory("alex", [
                    directory("project", [directory(".Trash", [file("fixture", 800_000_000)])]),
                    directory("Library", [directory(".Trash", [file("cached", 700_000_000)])]),
                ])
            ])
        let volumeLevel = directory("Volumes", [directory("Backup", [directory(".Trash", [file("old", 900_000_000)])])])

        let found = RecommendationEngine.analyze(
            result: result(root: directory("root", [impostors, volumeLevel])))

        #expect(!found.contains { $0.action == .emptyTrash })
    }

    @Test("Stale large downloads are flagged for review, not as safe")
    func flagsStaleDownloads() {
        let old = Date(timeIntervalSinceNow: -200 * 24 * 3600)
        let tree = directory(
            "Users", [directory("alex", [directory("Downloads", [file("installer.dmg", 3_000_000_000, accessed: old)])])])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))
        let download = found.first { $0.title == "installer.dmg" }

        // The user's own file: suggest, never classify as safe to delete unattended.
        #expect(download?.tier == .review)
    }

    @Test("Files with unknown access time are never flagged as stale")
    func unknownAccessTimeIsNotEvidence() {
        // atime is unavailable on noatime volumes. Absence of a date must not read as "old",
        // or every large file on such a volume would be proposed for deletion.
        let tree = directory(
            "Users", [directory("alex", [directory("Downloads", [file("mystery.iso", 5_000_000_000)])])])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        #expect(found.isEmpty)
    }

    @Test("Recently used large files are left alone")
    func recentFilesAreNotFlagged() {
        let recent = Date(timeIntervalSinceNow: -2 * 24 * 3600)
        let tree = directory(
            "Users", [directory("alex", [directory("Downloads", [file("current.zip", 3_000_000_000, accessed: recent)])])])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        #expect(found.isEmpty)
    }

    @Test("Safe suggestions sort ahead of review ones")
    func tiersOrderResults() {
        let old = Date(timeIntervalSinceNow: -400 * 24 * 3600)
        let tree = directory(
            "Users",
            [
                directory(
                    "alex",
                    [
                        directory("Downloads", [file("huge.iso", 9_000_000_000, accessed: old)]),
                        directory("proj", [directory(".build", [file("o", 1_000_000)])]),
                    ])
            ])

        let found = RecommendationEngine.analyze(result: result(root: directory("root", [tree])))

        // The small safe item outranks the far larger risky one: acting on it needs no thought.
        #expect(found.first?.tier == .safe)
    }
}

@Suite("Trash service")
struct TrashServiceTests {

    @Test("Files move to the Trash and can be restored")
    func roundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disker-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("scratch.bin")
        try Data(count: 2048).write(to: target)

        let (trashed, failures) = TrashService.moveToTrash(paths: [target.path])
        #expect(failures.isEmpty)
        #expect(trashed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        // The property the whole design rests on: a deletion is always reversible.
        let restoreFailures = TrashService.restore(trashed)
        #expect(restoreFailures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: target.path))

        try? FileManager.default.removeItem(at: target)
    }

    @Test("Emptying clears the folder's contents and keeps the folder")
    func emptyingClearsContents() throws {
        let trash = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disker-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: trash) }

        let loose = trash.appendingPathComponent("loose.bin")
        try Data(count: 4096).write(to: loose)
        let nested = trash.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 8192).write(to: nested.appendingPathComponent("inner.bin"))

        let (freed, failures) = TrashService.emptyTrash(at: trash.path)

        #expect(failures.isEmpty)
        // Allocated size rounds up to whole blocks, so this is a floor rather than an exact
        // figure — what matters is that both items were counted.
        #expect(freed >= 12288)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        // macOS expects the Trash folder itself to keep existing.
        #expect(FileManager.default.fileExists(atPath: trash.path))
    }

    @Test("Emptying a folder that is not there is reported, not thrown")
    func emptyingMissingFolderIsReported() {
        let (freed, failures) = TrashService.emptyTrash(at: "/nonexistent-\(UUID().uuidString)")
        #expect(freed == 0)
        #expect(failures.count == 1)
    }

    @Test("A missing path fails without throwing")
    func missingPathIsReported() {
        let (trashed, failures) = TrashService.moveToTrash(
            paths: ["/nonexistent-\(UUID().uuidString)"])

        #expect(trashed.isEmpty)
        #expect(failures.count == 1)
    }

    @Test("One failure does not block the rest of a batch")
    func partialSuccess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("disker-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let good = directory.appendingPathComponent("good.bin")
        try Data(count: 512).write(to: good)

        let (trashed, failures) = TrashService.moveToTrash(
            paths: ["/nonexistent-\(UUID().uuidString)", good.path])

        #expect(trashed.count == 1)
        #expect(failures.count == 1)

        _ = TrashService.restore(trashed)
        try? FileManager.default.removeItem(at: good)
    }
}

@Suite("Category totals")
struct CategoryTotalsTests {

    private func file(_ name: String, _ size: UInt64) -> FileNode {
        FileNode(name: name, size: size, kind: .file, fileCount: 1)
    }

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(
            name: name, size: children.reduce(0) { $0 + $1.size }, kind: .directory,
            children: children, fileCount: children.reduce(0) { $0 + $1.fileCount })
    }

    private var home: FileNode {
        directory("Users", [
            directory("alex", [
                directory("Documents", [file("thesis.pdf", 400)]),
                directory("Pictures", [file("shoot.raw", 300)]),
                directory("Movies", [file("cut.mov", 200)]),
                file("loose.txt", 100),
            ])
        ])
    }

    @Test("Drilling in still reports the colours the chart draws")
    func totalsInsideAHomeDirectory() {
        // The legend used to classify only the direct children of the charted folder. Inside
        // `Users` those are all `Users/<account>`, so it collapsed to one entry while the
        // rings below were drawn in four colours.
        let totals = StorageCategory.totals(for: home, rootComponents: ["Users"])
        let byCategory = Dictionary(uniqueKeysWithValues: totals.map { ($0.category, $0.size) })

        #expect(byCategory[.documents] == 400)
        #expect(byCategory[.pictures] == 300)
        #expect(byCategory[.media] == 200)
        // Files sitting directly in the home directory, which belong to no deeper category.
        #expect(byCategory[.users] == 100)
    }

    @Test("Every byte is counted exactly once")
    func totalsDoNotDoubleCount() {
        let root = directory("root", [home, directory("Applications", [file("Thing.app", 500)])])
        let totals = StorageCategory.totals(for: root)

        #expect(totals.reduce(UInt64(0)) { $0 + $1.size } == root.size)
        #expect(totals.first?.size == 500)  // sorted largest first
    }

    @Test("Sizes are attributed to the folder that decides the category")
    func totalsStopWhereClassificationSettles() {
        // Nothing below `Applications` can change the answer, so the walk must not descend
        // into every app bundle to find that out.
        let apps = directory("Applications", [
            directory("Thing.app", [directory("Contents", [file("binary", 900)])])
        ])
        let totals = StorageCategory.totals(for: directory("root", [apps]))

        #expect(totals.count == 1)
        #expect(totals.first?.category == .applications)
        #expect(totals.first?.size == 900)
    }
}
