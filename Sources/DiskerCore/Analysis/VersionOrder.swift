import Foundation

/// Orders version-shaped directory names.
///
/// Three rules need this and all three would get it wrong on their own. Version directories
/// are compared as strings by every obvious implementation, and a string comparison puts
/// `13.9.0` above `13.41.0` because `9` sorts after `4`. That is the difference between
/// deleting the stale copy of a browser extension and deleting the live one.
///
/// Parsing is deliberately strict. `parse` returns nil for anything that is not a run of
/// numbers separated by `.` or `_`, and callers are expected to treat a nil as a reason to
/// suggest nothing at all: a directory that does not look the way the rule assumed means the
/// layout was misread, and the answer to "I do not understand this directory" is silence
/// rather than a partial guess.
public enum VersionOrder {

    /// Numeric components, or nil when `name` is not a version.
    ///
    /// Chromium unpacks extensions into `13.41.0.0_0`, so `_` separates a component just as
    /// `.` does. Trailing text of any kind disqualifies the name; `1.2.3-beta` is not ordered
    /// here because there is no correct answer for where a pre-release sits.
    public static func parse(_ name: String) -> [Int]? {
        // Empty components are kept rather than dropped, so `1..2` and `1.2.` fail to parse
        // instead of quietly reading as `1.2`. Strictness is the whole point: a name that is
        // not the shape the rule assumed has to be visible as such.
        let parts = name.split(
            omittingEmptySubsequences: false, whereSeparator: { $0 == "." || $0 == "_" })
        guard !parts.isEmpty else { return nil }

        var components: [Int] = []
        components.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        return components
    }

    /// Orders two version names, comparing component by component as numbers.
    ///
    /// A shorter version sorts below a longer one that shares its prefix, so `1.2` is older
    /// than `1.2.1`. Returns nil when either side is unparseable, which callers must not
    /// treat as equality.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }

        for index in 0..<max(left.count, right.count) {
            // A missing component is zero, so 1.2 and 1.2.0 are the same version.
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The names that are not the newest, given a set of siblings.
    ///
    /// Returns nil if *any* sibling fails to parse. That is the invariant the sibling rules
    /// rest on: one unexpected name means the directory is not the shape the rule assumed, and
    /// keeping the highest of a set you have misread is how the live copy gets deleted.
    /// A set of fewer than two also returns nil, which makes "never uninstall the only version
    /// of something" fall out for free rather than needing a guard in every caller.
    public static func superseded(among names: [String]) -> [String]? {
        guard names.count >= 2 else { return nil }
        guard names.allSatisfy({ parse($0) != nil }) else { return nil }

        guard
            let newest = names.max(by: { compare($0, $1) == .orderedAscending })
        else { return nil }
        // Compared by value, not by spelling: `1.2` and `1.2.0` are the same version, and
        // filtering on string inequality would have picked one of them arbitrarily and called
        // the other stale. Every name tied for newest is kept.
        return names.filter { compare($0, newest) != .orderedSame }
    }
}
