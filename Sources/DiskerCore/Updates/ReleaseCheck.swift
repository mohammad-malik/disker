import Foundation

/// A Disker release newer than the one running.
public struct AvailableRelease: Equatable, Sendable {
    /// The version, without the tag's leading `v`.
    public let version: String
    public let title: String
    public let url: URL
}

/// Asks GitHub whether a newer Disker has been published.
///
/// The only network request Disker makes, and it exists because Disker carries RemoveMacAI:
/// that copy goes stale as macOS changes, and a fix reaches nobody until they know there is
/// a release to download. Sends nothing but the request itself.
public enum ReleaseCheck {
    /// `/latest` skips drafts and prereleases, so a beta is never offered as an update.
    public static let latestURL = URL(
        string: "https://api.github.com/repos/mohammad-malik/disker/releases/latest")!

    /// The release described by a `/releases/latest` response, if it is newer than
    /// `current`.
    ///
    /// Nil whenever there is any doubt — unreadable JSON, a tag that is not a plain version,
    /// a version that is not higher. Offering a wrong update is worse than missing one, which
    /// the next launch will catch.
    public static func newer(than current: String, payload: Data) -> AvailableRelease? {
        guard
            let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let link = json["html_url"] as? String,
            let url = URL(string: link)
        else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard VersionOrder.compare(version, current) == .orderedDescending else { return nil }

        let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AvailableRelease(version: version, title: name ?? "Disker \(version)", url: url)
    }

    /// Fetches the latest release and compares it with `current`. Nil on any failure,
    /// offline included.
    public static func fetch(
        current: String, session: URLSession = .shared
    ) async -> AvailableRelease? {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard
            let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return newer(than: current, payload: data)
    }
}
