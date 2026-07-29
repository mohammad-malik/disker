import Foundation
import Testing

@testable import DiskerCore

/// Guards the rules that stop Disker recommending the deletion of installed software.
///
/// A real scan of this machine listed `/opt/homebrew/lib/node_modules` and
/// `~/.bun/install/global/node_modules` under "Safe to remove". Both contain globally
/// installed CLI tools; removing them uninstalls software rather than reclaiming build
/// output that regenerates for free.
@Suite("Safety policy")
struct SafetyPolicyTests {

    private let policy = SafetyPolicy(protectedPatterns: [
        "/Users/tester/.gradle/caches/*",
        "/Users/tester/Library/Caches/JetBrains*",
    ])

    @Test("Global npm install roots are excluded on both architectures")
    func excludesGlobalNpmRoots() {
        #expect(policy.isExcluded("/opt/homebrew/lib/node_modules"))
        #expect(policy.isExcluded("/usr/local/lib/node_modules"))
        #expect(policy.isExcluded("/opt/homebrew/lib/node_modules/@anthropic-ai"))
    }

    @Test("Other package managers' global roots are excluded")
    func excludesOtherPackageManagers() {
        #expect(policy.isExcluded("/Users/tester/.bun/install/global"))
        #expect(policy.isExcluded("/Users/tester/.nvm/versions/node/v20.0.0"))
        #expect(policy.isExcluded("/Users/tester/.volta/tools/image/node"))
        #expect(policy.isExcluded("/opt/homebrew/Cellar/node/21.0.0"))
    }

    @Test("Data volume paths are folded onto their user-facing form")
    func normalisesDataVolumePaths() {
        // Scanning the data volume produces this prefix while every whitelist entry is
        // written as /Users/…; without folding them together no protection ever matched.
        #expect(policy.isExcluded("/System/Volumes/Data/opt/homebrew/lib/node_modules"))
        #expect(
            policy.isExcluded("/System/Volumes/Data/Users/tester/Library/Caches/JetBrains"))
    }

    @Test("Whitelisted paths are excluded")
    func honoursWhitelist() {
        #expect(policy.isExcluded("/Users/tester/.gradle/caches"))
        #expect(policy.isExcluded("/Users/tester/.gradle/caches/modules-2"))
    }

    @Test("A parent of protected content is not offered, but is still traversed")
    func parentOfProtectedIsNotExcluded() {
        // ~/.gradle holds the protected caches, so it must not be offered wholesale — but
        // treating that as a traversal stop made every ancestor protected and pruned the
        // entire home directory, which is how "Empty the Trash" disappeared from the list.
        #expect(policy.containsProtectedContent("/Users/tester/.gradle"))
        #expect(!policy.isExcluded("/Users/tester/.gradle"))

        #expect(policy.containsProtectedContent("/Users/tester"))
        #expect(!policy.isExcluded("/Users/tester"))
    }

    @Test("Ordinary project directories are untouched by the policy")
    func ordinaryProjectsAreNotProtected() {
        let path = "/Users/tester/Documents/myapp/node_modules"
        #expect(!policy.isExcluded(path))
        #expect(!policy.containsProtectedContent(path))
        #expect(!policy.isToolRuntime(path))
    }

    @Test("Tool runtime caches are recognised so they can be demoted")
    func identifiesToolRuntimes() {
        #expect(policy.isToolRuntime("/Users/tester/.cache/codex-runtimes/primary"))
        #expect(
            policy.isToolRuntime("/Users/tester/Library/Application Support/Zed/node/cache"))
        #expect(!policy.isToolRuntime("/Users/tester/Documents/app/node_modules"))
    }

    @Test("Managed prefixes are excluded wholesale")
    func excludesManagedPrefixes() {
        // __pycache__ inside a Homebrew-installed package belongs to that package.
        #expect(
            policy.isExcluded("/opt/homebrew/share/google-cloud-sdk/lib/googlecloudsdk"))
        #expect(policy.isExcluded("/System/Library/Frameworks"))
    }
}

@Suite("Recommendation safety integration")
struct RecommendationSafetyTests {

    private func file(_ name: String, _ size: UInt64) -> FileNode {
        FileNode(name: name, size: size, kind: .file)
    }

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(
            name: name,
            size: children.reduce(0) { $0 &+ $1.size },
            kind: .directory,
            children: children,
            fileCount: children.reduce(0) { $0 + $1.fileCount })
    }

    @Test("Globally installed CLI tools are never suggested")
    func doesNotSuggestGlobalInstalls() {
        // The exact layout that produced the bug: Homebrew's global npm tree.
        let tree = directory(
            "opt",
            [
                directory(
                    "homebrew",
                    [
                        directory(
                            "lib",
                            [directory("node_modules", [file("claude.js", 1_500_000_000)])])
                    ])
            ])

        let found = RecommendationEngine.analyze(
            result: ScanResult(
                root: directory("root", [tree]), rootPath: "/", duration: 1,
                inaccessibleCount: 0, deduplicatedBytes: 0),
            policy: SafetyPolicy())

        #expect(found.isEmpty)
    }

    @Test("System power logs are not mistaken for Xcode archives")
    func doesNotMistakePowerLogsForXcode() {
        // A bare "Archives" component matched /private/var/db/powerlog/Library/BatteryLife,
        // which offered system power logs for deletion under an Xcode heading.
        let tree = directory(
            "private",
            [
                directory(
                    "var",
                    [
                        directory(
                            "db",
                            [
                                directory(
                                    "powerlog",
                                    [
                                        directory(
                                            "Library",
                                            [
                                                directory(
                                                    "BatteryLife",
                                                    [
                                                        directory(
                                                            "Archives",
                                                            [file("log", 12_000_000)])
                                                    ])
                                            ])
                                    ])
                            ])
                    ])
            ])

        let found = RecommendationEngine.analyze(
            result: ScanResult(
                root: directory("root", [tree]), rootPath: "/", duration: 1,
                inaccessibleCount: 0, deduplicatedBytes: 0),
            policy: SafetyPolicy())

        #expect(found.isEmpty)
    }

    @Test("Artifacts beside protected content are still found")
    func findsArtifactsBesideProtectedContent() {
        // The home directory contains protected content, but must still be walked.
        let tree = directory(
            "Users",
            [
                directory(
                    "tester",
                    [
                        directory(".gradle", [directory("caches", [file("a", 5_000_000)])]),
                        directory(
                            "project", [directory("node_modules", [file("b", 800_000_000)])]),
                    ])
            ])

        let found = RecommendationEngine.analyze(
            result: ScanResult(
                root: directory("root", [tree]), rootPath: "/", duration: 1,
                inaccessibleCount: 0, deduplicatedBytes: 0),
            policy: SafetyPolicy(protectedPatterns: ["/Users/tester/.gradle/caches/*"]))

        #expect(found.count == 1)
        #expect(found.first?.title.contains("node_modules") == true)
    }
}
