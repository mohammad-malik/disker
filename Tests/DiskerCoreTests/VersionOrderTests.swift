import Foundation
import Testing

@testable import DiskerCore

@Suite("Version ordering")
struct VersionOrderTests {

    @Test("Components compare as numbers, not as text")
    func numericComparison() {
        // The bug this type exists to prevent: as strings, "13.9.0" sorts above "13.41.0"
        // because "9" comes after "4", which deletes the live extension and keeps the stale one.
        #expect(VersionOrder.compare("13.41.0", "13.9.0") == .orderedDescending)
        #expect(VersionOrder.compare("13.9.0", "13.41.0") == .orderedAscending)
        #expect(VersionOrder.compare("2.0.0", "10.0.0") == .orderedAscending)
    }

    @Test("Underscores separate components, as Chromium writes them")
    func underscoreSeparator() {
        #expect(VersionOrder.parse("13.41.0.0_0") == [13, 41, 0, 0, 0])
        #expect(VersionOrder.compare("13.41.0.0_0", "13.38.2.0_0") == .orderedDescending)
    }

    @Test("A missing trailing component counts as zero")
    func shorterVersions() {
        #expect(VersionOrder.compare("1.2", "1.2.0") == .orderedSame)
        #expect(VersionOrder.compare("1.2", "1.2.1") == .orderedAscending)
    }

    @Test("Anything that is not a plain version fails to parse")
    func strictParsing() {
        #expect(VersionOrder.parse("1.2.3-beta") == nil)
        #expect(VersionOrder.parse("nightly") == nil)
        #expect(VersionOrder.parse("") == nil)
        #expect(VersionOrder.parse("1..2") == nil)
        #expect(VersionOrder.compare("1.0", "nightly") == nil)
    }

    @Test("The newest is kept and the rest are superseded")
    func supersededSet() {
        #expect(
            VersionOrder.superseded(among: ["13.38.2.0_0", "13.41.0.0_0"]) == ["13.38.2.0_0"])
        #expect(
            VersionOrder.superseded(among: ["1.0", "3.0", "2.0"])?.sorted() == ["1.0", "2.0"])
    }

    @Test("Two spellings of the same version are both kept")
    func tiedVersionsAreBothKept() {
        // `1.2` and `1.2.0` compare equal. Filtering on string inequality picked one of them
        // arbitrarily and offered the other, which is the live version half the time.
        #expect(VersionOrder.superseded(among: ["1.2", "1.2.0"]) == [])
        #expect(VersionOrder.superseded(among: ["1.0", "2.0", "2.0.0"]) == ["1.0"])
    }

    @Test("One unparseable sibling silences the whole set")
    func oneOddNameSilencesTheSet() {
        // A name the rule did not expect means the layout was misread, and keeping the highest
        // of a set you have misread is how the live copy gets deleted.
        #expect(VersionOrder.superseded(among: ["1.0", "2.0", "scratch"]) == nil)
    }

    @Test("A lone version is never superseded by anything")
    func singleVersionIsNeverOffered() {
        // Generalises "never uninstall the only version of something": a Homebrew formula or
        // an app with one version directory has nothing stale in it.
        #expect(VersionOrder.superseded(among: ["1.0"]) == nil)
        #expect(VersionOrder.superseded(among: []) == nil)
    }
}
