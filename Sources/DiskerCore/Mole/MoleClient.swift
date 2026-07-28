import Foundation

/// Talks to the Mole CLI (https://github.com/tw93/mole).
///
/// Mole's `clean` command is an interactive TUI with no headless execute mode, so Disker
/// never runs it directly. Instead it runs `mole clean --dry-run`, which *is* non-interactive,
/// to find out what could be reclaimed — and leaves the actual deletion to Mole itself,
/// launched in a terminal where the user can review it and authorise sudo.
public struct MoleClient: Sendable {

    /// Verified against Mole 1.43.1. Parsing is defensive rather than version-gated: a
    /// changed format degrades to `.unparseable` instead of producing wrong numbers.
    public static let verifiedVersion = "1.43.1"

    private let searchPaths = [
        "/opt/homebrew/bin/mole",  // Apple silicon Homebrew
        "/usr/local/bin/mole",     // Intel Homebrew
    ]

    public init() {}

    /// Finds the Mole binary, preferring known Homebrew locations before falling back to
    /// the user's `PATH`. Hardcoding a single path would break on Intel Macs.
    public func locateBinary() -> String? {
        for candidate in searchPaths where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // `which` runs under a login shell so it sees the user's real PATH, not the
        // minimal environment a GUI app inherits from launchd.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which mole"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        } catch {
            return nil
        }
        return nil
    }

    public func version() async -> String? {
        guard let binary = locateBinary() else { return nil }
        guard let output = try? await run(binary: binary, arguments: ["--version"]) else {
            return nil
        }
        // e.g. "Mole version 1.43.1"
        for line in ANSIStripper.strip(output).split(separator: "\n") {
            if let range = line.range(of: "version ") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Runs `mole clean --dry-run` and parses the result. Never deletes anything.
    public func dryRun() async throws -> MoleReport {
        guard let binary = locateBinary() else {
            return .unparseable(reason: "Mole is not installed.")
        }
        let output = try await run(binary: binary, arguments: ["clean", "--dry-run"])
        return MoleOutputParser.parse(ANSIStripper.strip(output))
    }

    private func run(binary: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                // Mole reads stdin for its interactive menus. Handing it /dev/null guarantees
                // it cannot block waiting for a keypress that will never come.
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Read before waiting: a full pipe buffer would deadlock the child.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}
