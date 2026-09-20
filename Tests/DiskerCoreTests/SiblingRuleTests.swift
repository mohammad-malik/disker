import Foundation
import Testing

@testable import DiskerCore

@Suite("Rules that read a set of siblings")
struct SiblingRuleTests {

    private let home = "/Users/tester"

    private func file(_ name: String, _ size: UInt64, accessed: Date? = nil) -> FileNode {
        FileNode(name: name, size: size, kind: .file, fileCount: 1, accessTime: accessed)
    }

    private func directory(
        _ name: String, _ children: [FileNode], accessed: Date? = nil
    ) -> FileNode {
        FileNode(
            name: name, size: children.reduce(0) { $0 + $1.size }, kind: .directory,
            children: children, fileCount: children.reduce(0) { $0 + $1.fileCount },
            accessTime: accessed)
    }

    /// Wraps `children` in /Users/tester and analyses the result.
    private func analyze(_ children: [FileNode]) -> [Recommendation] {
        let root = directory("root", [directory("Users", [directory("tester", children)])])
        return RecommendationEngine.analyze(
            result: ScanResult(
                root: root, rootPath: "/", duration: 0, inaccessibleCount: 0,
                deduplicatedBytes: 0),
            policy: SafetyPolicy(home: home))
    }

    // MARK: - Browser extensions

    private func extensionsTree(_ versions: [String]) -> [FileNode] {
        [
            directory("Library", [
                directory("Application Support", [
                    directory("Arc", [
                        directory("User Data", [
                            directory("Default", [
                                directory("Extensions", [
                                    directory(
                                        "nkbihfbeogaeaoehlefnkodbefgpgknn",
                                        versions.map { directory($0, [file("bundle.js", 80_000_000)]) })
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ]
    }

    @Test("The stale extension version is offered and the newest is kept")
    func staleExtensionVersions() {
        let found = analyze(extensionsTree(["13.38.2.0_0", "13.41.0.0_0"]))

        #expect(found.count == 1)
        #expect(found.first?.path.hasSuffix("13.38.2.0_0") == true)
        #expect(found.first?.tier == .safe)
    }

    @Test("A lone extension version is never offered")
    func loneExtensionVersion() {
        // Deleting it would remove the extension rather than tidy up after it.
        #expect(analyze(extensionsTree(["13.41.0.0_0"])).isEmpty)
    }

    @Test("A project folder named Extensions is not a browser profile")
    func extensionsFolderOutsideAProfile() {
        // A parent named `Extensions` was once the only anchor, which made somebody's own
        // versioned folder look like a browser extension and offered `1.0` as safe to delete.
        let found = analyze([
            directory("project", [
                directory("Extensions", [
                    directory("widget", [
                        directory("1.0", [file("w.js", 40_000_000)]),
                        directory("2.0", [file("w.js", 42_000_000)]),
                    ])
                ])
            ])
        ])

        #expect(!found.contains { $0.family.key == "chromium-extension-versions" })
    }

    @Test("An unexpected name inside the extension silences the whole set")
    func unparseableSiblingSilencesExtensions() {
        #expect(analyze(extensionsTree(["13.38.2.0_0", "13.41.0.0_0", "scratch"])).isEmpty)
    }

    // MARK: - Gradle

    @Test("Gradle keeps the version you built with most recently")
    func gradleVersionCaches() {
        let recent = Date(timeIntervalSinceNow: -2 * 24 * 3600)
        let old = Date(timeIntervalSinceNow: -200 * 24 * 3600)
        let found = analyze([
            directory(".gradle", [
                directory("caches", [
                    directory("8.13", [file("blob", 1_100_000_000)], accessed: recent),
                    directory("9.5.1", [file("blob", 1_300_000_000)], accessed: old),
                ])
            ])
        ])

        // Ordered by use, not by version number: 9.5.1 is the higher version and the dead one.
        #expect(found.count == 1)
        #expect(found.first?.title == "Gradle 9.5.1")
    }

    @Test("A Gradle cache with no access time is kept")
    func gradleUnknownAccessTime() {
        // nil means unknown, never old — the same discipline the stale file rule follows.
        let recent = Date(timeIntervalSinceNow: -2 * 24 * 3600)
        let found = analyze([
            directory(".gradle", [
                directory("caches", [
                    directory("8.13", [file("blob", 1_000_000_000)], accessed: recent),
                    directory("9.5.1", [file("blob", 1_000_000_000)]),
                ])
            ])
        ])

        #expect(found.isEmpty)
    }

    // MARK: - App version directories

    @Test("An app's superseded build is offered, a lone build is not")
    func appVersionDirectories() {
        let two = analyze([
            directory("Library", [
                directory("Application Support", [
                    directory("discord", [
                        directory("0.0.397", [file("app.asar", 282_000_000)]),
                        directory("0.0.401", [file("app.asar", 284_000_000)]),
                    ])
                ])
            ])
        ])
        #expect(two.count == 1)
        #expect(two.first?.path.hasSuffix("0.0.397") == true)
        #expect(two.first?.title == "discord 0.0.397")

        let one = analyze([
            directory("Library", [
                directory("Application Support", [
                    directory("discord", [directory("0.0.397", [file("app.asar", 282_000_000)])])
                ])
            ])
        ])
        #expect(one.isEmpty)
    }

    @Test("An unnamed app with version-shaped folders is left alone")
    func versionShapeAloneIsNotEvidence() {
        // Versioned backups, per-release document stores and database directories look exactly
        // like a self-updating app from the outside. Nothing about the shape says the app
        // ignores the older ones, so only named layouts qualify.
        let found = analyze([
            directory("Library", [
                directory("Application Support", [
                    directory("SomeVendor", [
                        directory("1.2.3", [file("payload", 500_000_000)]),
                        directory("2.0.0", [file("payload", 500_000_000)]),
                    ])
                ])
            ])
        ])

        #expect(!found.contains { $0.family.key == "stale-app-versions" })
    }

    // MARK: - Android SDK

    @Test("Older Android build-tools are offered for review, never as safe")
    func androidBuildTools() {
        // A project's build.gradle can pin an exact version, and no directory name says which.
        let found = analyze([
            directory("Library", [
                directory("Android", [
                    directory("sdk", [
                        directory("build-tools", [
                            directory("34.0.0", [file("aapt2", 180_000_000)]),
                            directory("35.0.0", [file("aapt2", 190_000_000)]),
                            directory("36.0.0", [file("aapt2", 192_000_000)]),
                        ]),
                        // adb and fastboot live here and everything depends on them.
                        directory("platform-tools", [file("adb", 38_000_000)]),
                    ])
                ])
            ])
        ])

        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.tier == .review })
        #expect(found.map(\.title).sorted() == ["Android build-tools 34.0.0", "Android build-tools 35.0.0"])
        #expect(!found.contains { $0.path.contains("platform-tools") })
    }

    @Test("Android platforms are ordered by API level, not by their directory name")
    func androidPlatforms() {
        // Platform directories are `android-36`, which is not a version string. The rule
        // silently never fired until the prefix was stripped before comparing.
        let found = analyze([
            directory("Library", [
                directory("Android", [
                    directory("sdk", [
                        directory("platforms", [
                            directory("android-34", [file("android.jar", 130_000_000)]),
                            directory("android-35", [file("android.jar", 134_000_000)]),
                            directory("android-36", [file("android.jar", 138_000_000)]),
                        ])
                    ])
                ])
            ])
        ])

        #expect(found.count == 2)
        #expect(found.map(\.title).sorted()
            == ["Android platforms android-34", "Android platforms android-35"])
    }

    @Test("A preview platform silences the set rather than being guessed at")
    func androidPreviewPlatform() {
        // Real SDKs carry names like `android-TiramisuPrivacySandbox`, and there is no sane
        // place to order those against a number.
        let found = analyze([
            directory("Library", [
                directory("Android", [
                    directory("sdk", [
                        directory("platforms", [
                            directory("android-35", [file("android.jar", 134_000_000)]),
                            directory("android-36", [file("android.jar", 138_000_000)]),
                            directory("android-TiramisuPrivacySandbox", [file("android.jar", 120_000_000)]),
                        ])
                    ])
                ])
            ])
        ])

        #expect(!found.contains { $0.family.key == "android-sdk-versions" })
    }

    // MARK: - Arc snapshots

    private func arcTree(snapshotCount: Int) -> [FileNode] {
        var children = [file("StorableSidebar.json", 3_500_000)]
        for index in 0..<snapshotCount {
            children.append(
                file(String(format: "StorableSidebar.2026-0%d-01-00-00-00-000.json", index % 9 + 1),
                     3_500_000))
        }
        return [directory("Library", [directory("Application Support", [directory("Arc", children)])])]
    }

    @Test("Old Arc snapshots are offered, the live file and the newest three are not")
    func arcSidebarSnapshots() {
        let found = analyze(arcTree(snapshotCount: 9))

        #expect(found.count == 6)
        // The live file has no timestamp and must never appear.
        #expect(!found.contains { $0.title == "StorableSidebar.json" })
        #expect(found.allSatisfy { $0.family.key == "arc-sidebar-snapshots" })
    }

    @Test("A handful of Arc snapshots is left alone")
    func fewArcSnapshots() {
        #expect(analyze(arcTree(snapshotCount: 4)).isEmpty)
    }

    // MARK: - The hook's effect on traversal

    @Test("Claiming a set does not stop the walk reaching its siblings")
    func claimedNamesDoNotHaltTheWalk() {
        // Arc's snapshots sit in a directory full of things the walker still has to see.
        var children = [file("StorableSidebar.json", 3_500_000)]
        for index in 1...9 {
            children.append(
                file("StorableSidebar.2026-0\(index)-01-00-00-00-000.json", 3_500_000))
        }
        children.append(directory("node_modules", [file("dep.js", 900_000_000)]))

        let found = analyze([
            directory("Library", [directory("Application Support", [directory("Arc", children)])])
        ])

        #expect(found.contains { $0.family.key == "node_modules" })
        #expect(found.contains { $0.family.key == "arc-sidebar-snapshots" })
    }
}
