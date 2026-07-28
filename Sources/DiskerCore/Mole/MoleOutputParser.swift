import Foundation

/// Parses the (ANSI-stripped) output of `mole clean --dry-run`.
///
/// The grammar, as emitted by Mole 1.43.1:
///
///     ➤ User essentials
///       → User app cache 111 items, 913.6MB dry
///       → Darwin user temp files, 142 old items, 0B dry
///
/// Sections start with `➤`, items with `→`. Each item ends with a size and the word `dry`.
///
/// This is scraping a human-facing TUI, so every rule below is written to fail closed:
/// anything that does not match is skipped, and a run that yields no categories at all is
/// reported as unparseable rather than as "0 bytes reclaimable" — the latter would be
/// indistinguishable from a genuinely clean system.
enum MoleOutputParser {

    private static let sizePattern = try! NSRegularExpression(
        pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*(TB|GB|MB|KB|B)\\b")

    /// Trailing item counts such as "111 items" or "142 old items".
    private static let trailingCountPattern = try! NSRegularExpression(
        pattern: "\\s+[0-9]+\\s+(old\\s+)?items?$")

    static func parse(_ output: String) -> MoleReport {
        var categories: [MoleCategory] = []
        var currentName: String?
        var currentItems: [MoleItem] = []

        func flush() {
            guard let name = currentName else { return }
            // Sections with nothing reclaimable are dropped: an empty card is noise.
            if !currentItems.isEmpty {
                categories.append(MoleCategory(name: name, items: currentItems))
            }
            currentName = nil
            currentItems = []
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("➤") {
                flush()
                currentName = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("→"), currentName != nil {
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let item = parseItem(body), item.size > 0 {
                    currentItems.append(item)
                }
            }
        }
        flush()

        guard !categories.isEmpty else {
            return .unparseable(
                reason: "No recognisable sections in Mole's output. "
                    + "Its format may have changed since version \(MoleClient.verifiedVersion).")
        }

        let total = categories.reduce(UInt64(0)) { $0 &+ $1.totalSize }
        return .parsed(categories: categories, totalReclaimable: total)
    }

    private static func parseItem(_ body: String) -> MoleItem? {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let matches = sizePattern.matches(in: body, options: [], range: range)
        // The size is the last measurement on the line; earlier numbers are item counts.
        guard let match = matches.last,
            let valueRange = Range(match.range(at: 1), in: body),
            let unitRange = Range(match.range(at: 2), in: body),
            let value = Double(body[valueRange])
        else { return nil }

        let size = bytes(value: value, unit: String(body[unitRange]))

        // Everything before the first comma is the label; strip any trailing item count.
        var name = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? body
        name = name.trimmingCharacters(in: .whitespaces)
        let nameRange = NSRange(name.startIndex..<name.endIndex, in: name)
        name = trailingCountPattern.stringByReplacingMatches(
            in: name, options: [], range: nameRange, withTemplate: "")
        name = name.trimmingCharacters(in: .whitespaces)

        return name.isEmpty ? nil : MoleItem(name: name, size: size)
    }

    /// Mole reports decimal units (913.6MB), matching Finder, so 1 KB is 1000 bytes here.
    private static func bytes(value: Double, unit: String) -> UInt64 {
        let multiplier: Double
        switch unit {
        case "TB": multiplier = 1_000_000_000_000
        case "GB": multiplier = 1_000_000_000
        case "MB": multiplier = 1_000_000
        case "KB": multiplier = 1_000
        default: multiplier = 1
        }
        return UInt64((value * multiplier).rounded())
    }
}
