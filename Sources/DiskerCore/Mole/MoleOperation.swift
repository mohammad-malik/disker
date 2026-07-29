import Foundation

/// The Mole commands Disker can run, and what each accepts.
///
/// Mirrors Mole 1.43.1's actual CLI rather than an idealised version of it — every option
/// here corresponds to a real flag, so the configuration screen cannot offer something the
/// binary will reject.
public enum MoleOperation: String, CaseIterable, Identifiable, Sendable {
    case clean
    case optimize
    case purge
    case installer
    case uninstall

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clean: return "Clean"
        case .optimize: return "Optimize"
        case .purge: return "Purge Project Artifacts"
        case .installer: return "Remove Installers"
        case .uninstall: return "Uninstall Apps"
        }
    }

    public var summary: String {
        switch self {
        case .clean:
            return "Caches, logs, temporary files, and leftovers from apps you already removed."
        case .optimize:
            return "Rebuilds system caches and services, and repairs safe maintenance issues."
        case .purge:
            return "Build artifacts in your project folders — node_modules, target, .venv and similar."
        case .installer:
            return "Downloaded .dmg, .pkg, .iso, .xip and .zip installers you no longer need."
        case .uninstall:
            return "Removes applications along with their support files and preferences."
        }
    }

    public var symbolName: String {
        switch self {
        case .clean: return "sparkles"
        case .optimize: return "wrench.and.screwdriver"
        case .purge: return "hammer"
        case .installer: return "shippingbox"
        case .uninstall: return "trash.square"
        }
    }

    /// Whether Mole prompts before acting. All of these are interactive, which is precisely
    /// why they run in an embedded terminal rather than silently.
    public var supportsWhitelist: Bool {
        self == .clean || self == .optimize
    }

    public var supportsExternalVolume: Bool { self == .clean }
    public var supportsCustomPaths: Bool { self == .purge }
    public var supportsIncludeEmpty: Bool { self == .purge }
    public var supportsPermanent: Bool { self == .uninstall }
    public var supportsAppNames: Bool { self == .uninstall }

    /// Needs administrator rights for full effect; Mole says so itself during a dry run.
    public var mayRequireSudo: Bool {
        self == .clean || self == .optimize
    }
}

/// A configured Mole invocation.
public struct MoleConfiguration: Sendable, Equatable {
    public var operation: MoleOperation = .clean
    /// Defaults on. A destructive tool should open on preview, not on execution.
    public var dryRun: Bool = true
    public var includeEmpty: Bool = false
    /// Bypasses the Trash entirely — Mole documents this as `rm -rf`, so it is off by
    /// default and called out in the UI rather than presented as an ordinary checkbox.
    public var permanent: Bool = false
    public var externalVolumePath: String = ""
    public var appNames: String = ""

    public init() {}

    /// Arguments for the configured run.
    public func arguments() -> [String] {
        var result = [operation.rawValue]

        if dryRun { result.append("--dry-run") }

        switch operation {
        case .clean:
            let path = externalVolumePath.trimmingCharacters(in: .whitespaces)
            if !path.isEmpty { result.append(contentsOf: ["--external", path]) }
        case .purge:
            if includeEmpty { result.append("--include-empty") }
        case .uninstall:
            if permanent { result.append("--permanent") }
            let names =
                appNames
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
                .filter { !$0.isEmpty }
            result.append(contentsOf: names)
        case .optimize, .installer:
            break
        }

        return result
    }

    /// The equivalent shell command, shown so the user can see exactly what will run.
    public func commandLine() -> String {
        (["mole"] + arguments()).joined(separator: " ")
    }

    /// True when the configuration will delete things.
    public var isDestructive: Bool { !dryRun }
}
