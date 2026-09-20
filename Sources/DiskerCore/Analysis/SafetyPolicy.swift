import Darwin
import Foundation

/// Decides what must never be suggested for deletion, and what deserves a second look.
///
/// The build-artifact rule matches on directory name, and that turned out to be far too
/// blunt. A real scan of this machine offered, under "Safe to remove":
///
///   * `/opt/homebrew/lib/node_modules` — every globally installed npm CLI, including the
///     user's own Claude Code install
///   * `~/.bun/install/global/node_modules` — the same thing for Bun
///
/// Those are not build output. They are installed programs, and removing them uninstalls
/// software rather than reclaiming space that rebuilds for free. A cleanup tool that
/// uninstalls your toolchain under a heading reading "Safe to remove" is worse than one that
/// finds nothing at all.
public struct SafetyPolicy: Sendable {

    /// Absolute paths, and `~`-relative patterns, that are never suggested.
    private let protectedPatterns: [String]

    public init(protectedPatterns: [String] = [], home: String = NSHomeDirectory()) {
        // The built-ins come first and are never optional. A user's Mole whitelist is a
        // statement about their machine; this list is a statement about what a cleanup tool
        // must not touch on anybody's machine.
        //
        // "Anybody's" is meant literally, which is why each `~` entry expands twice. Disker
        // scans the whole data volume, so a machine with more than one account has other
        // people's `.ssh` and cloud roots in the tree, and binding the list to the running
        // user's home would have left every one of them offerable. The `/Users/*` form covers
        // the others; the supplied home covers the case where it does not live under /Users at
        // all. The wildcard is deliberately loose — it matches across path separators, so it
        // over-protects a directory of the same name nested deeper, which is the direction to
        // err in.
        self.protectedPatterns =
            Self.protectedUserData.flatMap { pattern -> [String] in
                guard pattern.hasPrefix("~") else { return [pattern] }
                let relative = String(pattern.dropFirst())
                return [home + relative, "/Users/*" + relative]
            } + protectedPatterns
    }

    /// Things that look exactly like caches and are not.
    ///
    /// Every entry here was proposed as a deletion candidate by somebody, or sits one
    /// directory away from something that was. The failure this defends against is not a rule
    /// author writing a bad exclusion — it is a rule author six months from now who has never
    /// heard of `~/.codex/sessions`, sees a 1.1 GB directory inside a dotfile cache root, and
    /// writes the obvious rule. Per-rule exclusions only ever defend against the dangers the
    /// rule's author already imagined.
    private static let protectedUserData: [String] = [
        // Agent and editor history. Dot-directories full of large files, none of it cache:
        // 1.1 GB of session transcripts and 555 MB of project history on the machine this
        // list was written on.
        "~/.codex/sessions",
        "~/.codex/history.jsonl",
        "~/.claude/projects",
        "~/.claude/history.jsonl",
        // The editor's own record of edits that were never committed. For anyone who has
        // ever recovered work from it, this is the only copy.
        //
        // Spelled out per editor rather than as `*/User/History`. A pattern that starts with a
        // wildcard can be matched against a path, but it says nothing about *ancestors*: there
        // is no way to ask "could this pattern match something inside here" when the pattern
        // has no fixed root, so the ancestor check below could never protect the directories
        // above it. Absolute patterns keep that check meaningful.
        "~/Library/Application Support/Code/User/History",
        "~/Library/Application Support/Code - Insiders/User/History",
        "~/Library/Application Support/VSCodium/User/History",
        "~/Library/Application Support/Cursor/User/History",
        "~/Library/Application Support/Windsurf/User/History",
        "~/Library/Application Support/Antigravity/User/History",

        // Credentials, sitting inside or beside directories that are otherwise fair game.
        // `~/.gradle/gradle.properties` is the sharpest: the caches next to it are a rule we
        // actively want, and the signing keys are one directory over.
        "~/.aws",
        "~/.ssh",
        "~/.gnupg",
        "~/.kube",
        "~/.npmrc",
        "~/.gradle/gradle.properties",
        "~/.m2/settings.xml",
        "~/.cargo/credentials.toml",
        "~/.docker/config.json",

        // Cloud sync roots. A file inside one of these is not a local copy of something —
        // it *is* the thing, and deleting it propagates the delete to every other device the
        // user owns. The safe operation, evicting the local copy while keeping the remote,
        // exists only in each provider's own API. A filesystem tool must not attempt it.
        "~/Library/Mobile Documents",
        "~/Library/CloudStorage",
        "~/Dropbox",
        "~/Google Drive",
        "~/OneDrive",

        // A virtual machine is closer to a Documents folder than to a cache. Offering to
        // delete one is offering to delete a computer.
        "~/Parallels",
        "~/Virtual Machines.localized",
    ]

    /// Package-manager global install roots.
    ///
    /// Deleting any of these removes installed executables. Matched as path fragments so the
    /// rule holds for Intel (`/usr/local`) and Apple silicon (`/opt/homebrew`) alike.
    private static let globalInstallFragments: [String] = [
        "/opt/homebrew/lib/node_modules",
        "/usr/local/lib/node_modules",
        "/opt/local/lib/node_modules",
        "/.bun/install/global",
        "/.npm-global",
        "/.yarn/global",
        "/.config/yarn/global",
        "/pnpm/global",
        "/.local/share/pnpm",
        "/.nvm/versions",
        "/.volta/tools",
        "/.asdf/installs",
        "/.rbenv/versions",
        "/.pyenv/versions",
        "/Cellar/",           // Homebrew's own store
        "/.cargo/bin",
        "/go/pkg/mod",        // module cache; re-downloading is expensive and offline-hostile
    ]

    /// Runtime caches an installed tool depends on.
    ///
    /// These do regenerate, so they are not protected outright — but removing one breaks the
    /// tool until it can re-download, which is not what "safe" should mean. They are demoted
    /// to the review tier instead of being offered as free wins.
    private static let toolRuntimeFragments: [String] = [
        "/.cache/codex-runtimes",
        "/Application Support/Zed/node",
        "/Application Support/Code/User/globalStorage",
        "/.cache/ms-playwright",
        "/.cursor/extensions",
        "/.vscode/extensions",
    ]

    /// Loads the user's Mole whitelist so Disker honours the same protections.
    ///
    /// If someone has told Mole to leave `~/.gradle/caches` alone, Disker offering to delete
    /// it is the app arguing with a decision the user already made.
    public static func loadingMoleWhitelist(
        home: String = NSHomeDirectory()
    ) -> SafetyPolicy {
        let path = home + "/.config/mole/whitelist"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            // `home` has to be forwarded even here. Without it the built-in protections expand
            // against the *process* user's home rather than the requested one, so scanning
            // another account leaves its transcripts, credentials and cloud roots unguarded.
            return SafetyPolicy(home: home)
        }
        let patterns =
            contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            // A bare sentinel, not a path.
            .filter { $0 != "FINDER_METADATA" }
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        return SafetyPolicy(protectedPatterns: patterns, home: home)
    }

    /// Scanning the data volume yields paths beginning `/System/Volumes/Data`, while every
    /// whitelist entry and every user-facing path is written as `/Users/…`. Without folding
    /// the two together, no whitelist pattern ever matched during a real scan — the
    /// protections silently did nothing.
    static func normalized(_ path: String) -> String {
        let dataPrefix = "/System/Volumes/Data"
        guard path.hasPrefix(dataPrefix) else { return path }
        let remainder = String(path.dropFirst(dataPrefix.count))
        return remainder.isEmpty ? "/" : remainder
    }

    /// Nothing at or below this path should be examined: it is managed software, or the user
    /// asked for it to be left alone. Traversal stops here.
    public func isExcluded(_ rawPath: String) -> Bool {
        let path = Self.normalized(rawPath)
        if Self.globalInstallFragments.contains(where: { path.contains($0) }) { return true }
        if Self.managedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return true
        }
        return protectedPatterns.contains { matches(path: path, pattern: $0) }
    }

    /// This directory must not be offered for deletion, but its children are still worth
    /// examining.
    ///
    /// Distinct from `isExcluded` on purpose. The whitelist protects `~/.gradle/caches`, so
    /// offering `~/.gradle` wholesale would destroy the protected contents — but treating the
    /// same rule as a traversal stop made every ancestor protected too, and pruned the entire
    /// home directory along with it. Refusing to *offer* is not a reason to stop *looking*.
    public func containsProtectedContent(_ rawPath: String) -> Bool {
        let path = Self.normalized(rawPath)
        return protectedPatterns.contains { pattern in
            let base = pattern.hasSuffix("/*") ? String(pattern.dropLast(2)) : pattern
            return Self.pattern(base, canMatchSomethingInside: path)
        }
    }

    /// Whether `pattern` can only ever match something strictly inside `path`.
    ///
    /// Comparing the pattern's text against the path directly is enough while patterns are
    /// literal, and wrong the moment one holds a wildcard: a Mole entry like
    /// `~/projects/*/node_modules/secrets` never looks like a descendant of
    /// `~/projects/app/node_modules` as text, so the directory above it could be offered whole
    /// and take the protected content with it. Components are compared pairwise instead, each
    /// with its own glob match, and the pattern has to run deeper than the path to be inside it.
    static func pattern(_ pattern: String, canMatchSomethingInside path: String) -> Bool {
        if pattern.hasPrefix(path + "/") { return true }
        // A pattern with no fixed root describes a shape, not a location, so nothing can be
        // concluded about what sits above it.
        guard pattern.hasPrefix("/") else { return false }

        let patternParts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard patternParts.count > pathParts.count else { return false }

        for (patternPart, pathPart) in zip(patternParts, pathParts) {
            guard fnmatch(String(patternPart), String(pathPart), 0) == 0 else { return false }
        }
        return true
    }

    /// Package-manager prefixes. Everything inside is installed and managed, so artifacts
    /// found there belong to a package rather than to the user's own work.
    private static let managedPrefixes: [String] = [
        "/opt/homebrew",
        "/usr/local/Cellar",
        "/usr/local/Caskroom",
        "/opt/local",
        "/nix/store",
        "/System",
        "/Library/Developer/CommandLineTools",
    ]

    /// True when removing this would break a working tool until it re-downloads.
    public func isToolRuntime(_ rawPath: String) -> Bool {
        let path = Self.normalized(rawPath)
        return Self.toolRuntimeFragments.contains { path.contains($0) }
    }

    /// Glob match, plus prefix matching so a pattern for a directory also covers its contents.
    private func matches(path: String, pattern: String) -> Bool {
        if fnmatch(pattern, path, 0) == 0 { return true }

        // `~/.gradle/caches/*` should protect the directory itself, not only what is inside.
        let base = pattern.hasSuffix("/*") ? String(pattern.dropLast(2)) : pattern
        if path == base || path.hasPrefix(base + "/") { return true }

        // A pattern ending in `*` used as a prefix, e.g. `…/Caches/JetBrains*`.
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }
}
