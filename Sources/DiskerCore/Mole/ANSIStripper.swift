import Foundation

/// Removes ANSI escape sequences from terminal output.
///
/// Mole colourises its output unconditionally — it does not detect that stdout is a pipe —
/// so every line arrives wrapped in escape codes that would otherwise end up inside parsed
/// names and sizes.
enum ANSIStripper {
    /// Matches CSI sequences (`ESC [ … final-byte`), which covers all the colour and cursor
    /// codes Mole emits.
    private static let pattern = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    static func strip(_ input: String) -> String {
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return pattern.stringByReplacingMatches(
            in: input, options: [], range: range, withTemplate: "")
    }
}
