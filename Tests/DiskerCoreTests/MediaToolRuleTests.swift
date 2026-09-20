import Foundation
import Testing

@testable import DiskerCore

@Suite("Creative and app cache rules")
struct MediaToolRuleTests {

    private func file(_ name: String, _ size: UInt64) -> FileNode {
        FileNode(name: name, size: size, kind: .file, fileCount: 1)
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

    @Test("Adobe's shared media cache is found under the user's own Application Support")
    func adobeMediaCache() {
        let found = analyze([
            directory("Library", [
                directory("Application Support", [
                    directory("Adobe", [
                        directory("Common", [
                            directory("Media Cache Files", [file("clip.cfa", 40_000_000_000)]),
                            // Installed encoder presets, not cache.
                            directory("AME", [file("presets.bin", 200_000_000)]),
                        ])
                    ])
                ])
            ])
        ])

        #expect(found.count == 1)
        #expect(found.first?.title == "Adobe media cache")
        #expect(found.first?.tier == .safe)
    }

    @Test("Premiere previews are offered and the auto-save beside them is not")
    func premierePreviewsNotAutoSave() {
        // Never a prefix match on "Adobe Premiere Pro ": the auto-save is the crash recovery
        // copy of the project, and losing one costs a day of work.
        let found = analyze([
            directory("Movies", [
                directory("ClientJob", [
                    directory("Adobe Premiere Pro Video Previews", [file("p.prv", 8_000_000_000)]),
                    directory("Adobe Premiere Pro Auto-Save", [file("job.prproj", 40_000_000)]),
                ])
            ])
        ])

        #expect(found.count == 1)
        #expect(found.first?.title == "Preview files in ClientJob")
    }

    @Test("Lightroom smart previews are told apart from ordinary previews")
    func smartPreviewsTestedFirst() {
        // "Smart Previews.lrdata" also ends in " Previews.lrdata". For a photographer working
        // away from their originals, the smart previews are the only editable copy they have.
        let found = analyze([
            directory("Pictures", [
                directory("Lightroom", [
                    directory("2026 Previews.lrdata", [file("p.dat", 20_000_000_000)]),
                    directory("2026 Smart Previews.lrdata", [file("s.dng", 9_000_000_000)]),
                    // The catalog itself.
                    file("2026.lrcat", 2_000_000_000),
                ])
            ])
        ])

        let smart = found.first { $0.family.key == "lightroom-smart-previews" }
        let plain = found.first { $0.family.key == "lightroom-previews" }

        #expect(smart?.tier == .review)
        #expect(plain?.tier == .safe)
        #expect(plain?.title == "Previews for 2026")
        #expect(!found.contains { $0.path.hasSuffix(".lrcat") })
    }

    @Test("Resolve's caches are safe and its proxies are review")
    func resolveCacheAndProxies() {
        let found = analyze([
            directory("Movies", [
                directory("ResolveMedia", [
                    directory("CacheClip", [file("c.mov", 60_000_000_000)]),
                    directory("ProxyMedia", [file("p.mov", 30_000_000_000)]),
                    // A colourist's graded stills, which regenerate from nothing.
                    directory(".gallery", [file("still.dpx", 400_000_000)]),
                ])
            ])
        ])

        #expect(found.first { $0.family.key == "resolve-cache" }?.tier == .safe)
        #expect(found.first { $0.family.key == "resolve-proxy" }?.tier == .review)
        #expect(!found.contains { $0.path.contains(".gallery") })
    }

    @Test("Unity's Library needs both siblings, and ~/Library never matches")
    func unityNeedsBothSiblings() {
        // The worst name collision in the set: Library is also the most important directory in
        // a macOS home folder.
        let real = analyze([
            directory("Projects", [
                directory("MyGame", [
                    directory("Assets", [file("scene.unity", 100_000_000)]),
                    directory("ProjectSettings", [file("settings.asset", 1_000_000)]),
                    directory("Library", [file("artifacts.db", 12_000_000_000)]),
                ])
            ])
        ])
        #expect(real.count == 1)
        #expect(real.first?.title == "Unity Library in MyGame")

        let homeLibrary = analyze([
            directory("Library", [
                directory("Application Support", [file("thing.dat", 5_000_000_000)])
            ])
        ])
        #expect(!homeLibrary.contains { $0.family.key == "unity-library" })

        // One sibling is not enough.
        let halfMatch = analyze([
            directory("Projects", [
                directory("NotUnity", [
                    directory("Assets", [file("a.png", 10_000_000)]),
                    directory("Library", [file("b.dat", 5_000_000_000)]),
                ])
            ])
        ])
        #expect(!halfMatch.contains { $0.family.key == "unity-library" })
    }

    @Test("Unreal needs a .uproject beside it, and Saved is never offered")
    func unrealNeedsUproject() {
        let found = analyze([
            directory("Projects", [
                directory("Sequence", [
                    file("Sequence.uproject", 4_000),
                    directory("DerivedDataCache", [file("ddc.udd", 40_000_000_000)]),
                    directory("Intermediate", [file("build.o", 8_000_000_000)]),
                    // Autosaves and crash recovery. Most cleanup guides say delete this.
                    directory("Saved", [file("autosave.umap", 2_000_000_000)]),
                ])
            ])
        ])

        #expect(found.count == 2)
        #expect(!found.contains { $0.path.hasSuffix("/Saved") })

        let noProject = analyze([
            directory("Projects", [
                directory("SomeFolder", [
                    directory("Intermediate", [file("x.o", 3_000_000_000)])
                ])
            ])
        ])
        #expect(!noProject.contains { $0.family.key == "unreal-derived-data" })
    }

    @Test("Electron caches are offered and the state beside them is not")
    func chromiumProfileCaches() {
        // A rule that reaches one directory too far logs the user out of everything.
        let found = analyze([
            directory("Library", [
                directory("Application Support", [
                    directory("Slack", [
                        directory("Code Cache", [file("js.bin", 300_000_000)]),
                        directory("GPUCache", [file("gpu.bin", 100_000_000)]),
                        directory("Cache", [directory("Cache_Data", [file("d.bin", 200_000_000)])]),
                        directory("Local Storage", [file("leveldb.ldb", 159_000_000)]),
                        directory("IndexedDB", [file("db.idb", 119_000_000)]),
                        directory("Local Extension Settings", [file("s.ldb", 42_000_000)]),
                    ])
                ])
            ])
        ])

        #expect(found.count == 3)
        #expect(found.allSatisfy { $0.family.key == "chromium-profile-cache" })
        #expect(!found.contains { $0.path.contains("Local Storage") })
        #expect(!found.contains { $0.path.contains("IndexedDB") })
        #expect(!found.contains { $0.path.contains("Local Extension Settings") })
        #expect(found.contains { $0.title == "Code Cache in Slack" })
    }
}
