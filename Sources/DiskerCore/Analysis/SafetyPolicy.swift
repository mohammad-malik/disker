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

    public init(protectedPatterns: [String] = []) {
        self.protectedPatterns = protectedPatterns
    }

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
            return SafetyPolicy()
        }
        let patterns =
            contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            // A bare sentinel, not a path.
            .filter { $0 != "FINDER_METADATA" }
            .map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        return SafetyPolicy(protectedPatterns: patterns)
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
            return base.hasPrefix(path + "/")
        }
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
