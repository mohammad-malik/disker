import Foundation
import Testing

@testable import DiskerCore

@Suite("Release check")
struct ReleaseCheckTests {

    private func payload(tag: String, name: String? = "Disker", url: String = "https://github.com/mohammad-malik/disker/releases/tag/x") -> Data {
        var json: [String: Any] = ["tag_name": tag, "html_url": url]
        if let name { json["name"] = name }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("A higher tag is offered, without its leading v")
    func newerRelease() {
        let release = ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v1.9", name: "Disker v1.9 — Debloat"))
        #expect(release?.version == "1.9")
        #expect(release?.title == "Disker v1.9 — Debloat")
    }

    @Test("The running version and anything older are not offered")
    func sameOrOlder() {
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v1.8")) == nil)
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v1.8.0")) == nil)
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v1.7")) == nil)
    }

    @Test("Versions compare as numbers, so 1.10 is newer than 1.9")
    func numericOrder() {
        #expect(ReleaseCheck.newer(than: "1.9", payload: payload(tag: "v1.10"))?.version == "1.10")
    }

    @Test("Anything unreadable offers nothing rather than a guess")
    func doubtMeansSilence() {
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "nightly")) == nil)
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v2.0-beta")) == nil)
        #expect(ReleaseCheck.newer(than: "dev", payload: payload(tag: "v2.0")) == nil)
        #expect(ReleaseCheck.newer(than: "1.8", payload: Data("not json".utf8)) == nil)
        #expect(ReleaseCheck.newer(than: "1.8", payload: Data(#"{"message":"Not Found"}"#.utf8)) == nil)
    }

    @Test("A release without a name gets one from its version")
    func missingName() {
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v1.9", name: nil))?.title == "Disker 1.9")
        #expect(ReleaseCheck.newer(than: "1.8", payload: payload(tag: "v1.9", name: ""))?.title == "Disker 1.9")
    }
}
