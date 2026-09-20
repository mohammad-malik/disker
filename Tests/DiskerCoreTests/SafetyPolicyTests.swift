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

@Suite("Protected user data")
struct ProtectedUserDataTests {

    private let home = "/Users/tester"

    private func file(_ name: String, _ size: UInt64, accessed: Date? = nil) -> FileNode {
        FileNode(name: name, size: size, kind: .file, fileCount: 1, accessTime: accessed)
    }

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        FileNode(
            name: name, size: children.reduce(0) { $0 + $1.size }, kind: .directory,
            children: children, fileCount: children.reduce(0) { $0 + $1.fileCount })
    }

    /// Every protected path, dressed up as bait: large, long untouched, and where the name
    /// allows, carrying something a rule already matches.
    private var baitedTree: FileNode {
        let old = Date(timeIntervalSinceNow: -400 * 24 * 3600)
        return directory("root", [
            directory("Users", [
                directory("tester", [
                    directory(".codex", [
                        directory("sessions", [file("transcript.jsonl", 4_000_000_000, accessed: old)]),
                        file("history.jsonl", 2_000_000_000, accessed: old),
                    ]),
                    directory(".claude", [
                        directory("projects", [file("history.jsonl", 3_000_000_000, accessed: old)])
                    ]),
                    directory(".aws", [file("credentials", 2_000_000_000, accessed: old)]),
                    directory(".gradle", [
                        file("gradle.properties", 1_500_000_000, accessed: old),
                        // The caches beside the signing keys are a rule we actively want.
                        directory("caches", [file("blob", 2_000_000_000, accessed: old)]),
                    ]),
                    directory("Library", [
                        directory("Mobile Documents", [
                            // Named so the build-artefact rule would match it.
                            directory("node_modules", [file("payload", 5_000_000_000)])
                        ]),
                        directory("CloudStorage", [
                            directory(".venv", [file("payload", 4_000_000_000)])
                        ]),
                    ]),
                    directory("Dropbox", [file("archive.zip", 6_000_000_000, accessed: old)]),
                    directory("Parallels", [file("Windows.pvm.bin", 60_000_000_000, accessed: old)]),
                    // Not protected, and the control for the assertion below: it proves the
                    // engine is producing suggestions for this tree at all.
                    directory("project", [
                        directory("node_modules", [file("dep.js", 900_000_000)])
                    ]),
                ])
            ])
        ])
    }

    private func analyze(_ root: FileNode) -> [Recommendation] {
        RecommendationEngine.analyze(
            result: ScanResult(
                root: root, rootPath: "/", duration: 0, inaccessibleCount: 0,
                deduplicatedBytes: 0),
            policy: SafetyPolicy(home: home))
    }

    @Test("Nothing protected is ever suggested, whatever the rule")
    func nothingProtectedIsOffered() {
        // One assertion over the whole engine rather than per rule, so it keeps holding for
        // rules that do not exist yet.
        let protectedPrefixes = [
            "/Users/tester/.codex/sessions", "/Users/tester/.codex/history.jsonl",
            "/Users/tester/.claude/projects", "/Users/tester/.aws",
            "/Users/tester/.gradle/gradle.properties",
            "/Users/tester/Library/Mobile Documents", "/Users/tester/Library/CloudStorage",
            "/Users/tester/Dropbox", "/Users/tester/Parallels",
        ]
        let offered = analyze(baitedTree).map(\.path)

        for path in offered {
            for prefix in protectedPrefixes {
                #expect(
                    path != prefix && !path.hasPrefix(prefix + "/"),
                    "suggested \(path), which is protected by \(prefix)")
            }
        }

        // Control, so the assertion above cannot pass by finding nothing at all. The bait
        // includes one unprotected artefact, and it has to come out.
        //
        // Pointing the policy at a different home no longer works as a control, which is the
        // point of the change that broke it: the built-ins now cover every account under
        // /Users rather than only the one running the app.
        #expect(offered.contains { $0.hasSuffix("/project/node_modules") })
    }

    @Test("Protecting the credentials does not protect the caches beside them")
    func theDenyListDoesNotEatTheApp() {
        // A deny-list that quietly swallows the app's value would pass the test above while
        // making Disker useless.
        let old = Date(timeIntervalSinceNow: -400 * 24 * 3600)
        let tree = directory("root", [
            directory("Users", [
                directory("tester", [
                    directory("project", [
                        directory("node_modules", [file("dep.js", 900_000_000, accessed: old)])
                    ])
                ])
            ])
        ])

        #expect(analyze(tree).contains { $0.path.hasSuffix("/project/node_modules") })
    }

    @Test("Loading a whitelist for another home protects that home")
    func whitelistLoadingKeepsTheRequestedHome() {
        // Both return paths dropped the supplied home, so the built-ins expanded against the
        // process user's home instead and the requested account was left unguarded.
        let policy = SafetyPolicy.loadingMoleWhitelist(home: "/Users/elsewhere")

        #expect(policy.isExcluded("/Users/elsewhere/.codex/sessions"))
        #expect(policy.isExcluded("/Users/elsewhere/Library/Mobile Documents"))
        #expect(!policy.isExcluded("/Users/elsewhere/Documents/project/node_modules"))
    }

    @Test("A directory above protected content is not offered, even through a wildcard")
    func ancestorDetectionUnderstandsGlobs() {
        // Comparing pattern text against the path only works while patterns are literal. A
        // Mole entry with a wildcard in the middle never looked like a descendant, so the
        // directory above it could be offered whole and take the protected content with it.
        let policy = SafetyPolicy(
            protectedPatterns: ["/Users/tester/projects/*/node_modules/secrets"], home: home)

        #expect(policy.containsProtectedContent("/Users/tester/projects/app/node_modules"))
        #expect(policy.containsProtectedContent("/Users/tester/projects/app"))
        #expect(policy.containsProtectedContent("/Users/tester/projects"))
        // A sibling that the pattern cannot reach stays offerable.
        #expect(!policy.containsProtectedContent("/Users/tester/other/node_modules"))
    }

    @Test("Editor local history protects the directories above it")
    func editorHistoryProtectsItsAncestors() {
        // 165 MB of uncommitted-edit history on the machine this was written on, under three
        // editors. The entry that was meant to cover them was `*/User/History`, which has no
        // fixed root and so could never protect an ancestor.
        let policy = SafetyPolicy(home: home)

        #expect(policy.isExcluded("/Users/tester/Library/Application Support/Code/User/History"))
        #expect(
            policy.containsProtectedContent("/Users/tester/Library/Application Support/Code/User"))
        #expect(policy.containsProtectedContent("/Users/tester/Library/Application Support/Cursor"))
    }

    @Test("Every account on the machine is protected, not just the one running Disker")
    func otherAccountsAreProtected() {
        // Disker scans the whole data volume, so a shared Mac has other people's home
        // directories in the tree. Binding the built-ins to the running user's home left every
        // other account's credentials and cloud roots offerable.
        let policy = SafetyPolicy(home: home)

        #expect(policy.isExcluded("/Users/somebody-else/.ssh"))
        #expect(policy.isExcluded("/Users/somebody-else/Library/CloudStorage"))
        #expect(policy.isExcluded("/Users/somebody-else/.codex/sessions"))
        #expect(policy.containsProtectedContent("/Users/somebody-else/Library"))
        // And the ordinary rules still work in that account.
        #expect(!policy.isExcluded("/Users/somebody-else/project/node_modules"))
    }

    @Test("A file inside a directory holding protected content is not offered")
    func filesGoThroughThePolicyToo() {
        // The bypass this gate closed: the file branch appended straight to the results and
        // consulted no policy, so only the walker stopping early ever protected anything.
        let old = Date(timeIntervalSinceNow: -400 * 24 * 3600)
        let tree = directory("root", [
            directory("Users", [
                directory("tester", [
                    directory(".aws", [file("backup.tar", 3_000_000_000, accessed: old)])
                ])
            ])
        ])

        #expect(analyze(tree).isEmpty)
    }
}
