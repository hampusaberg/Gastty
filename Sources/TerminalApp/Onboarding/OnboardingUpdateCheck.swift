import Foundation

/// Lightweight, pre-onboarding appcast check.
///
/// We need to compare the running version against whatever's at the
/// top of `appcast.xml` BEFORE the onboarding window appears — early
/// enough to nudge a user running a stale DMG (a colleague's old copy,
/// say) to grab the current release before they bother configuring it.
///
/// Why not use Sparkle's own API? Sparkle's check-for-updates flow
/// runs through `SPUStandardUpdaterController`, which immediately shows
/// its own UI when an update is available. We want our own framed
/// prompt with "Continue with this version" as a first-class option,
/// so this helper just downloads the feed, parses out the newest
/// `<sparkle:shortVersionString>`, and reports back. Sparkle still
/// owns the actual download / install path — we just trigger it
/// after the user agrees.
///
/// Network failures, timeouts, or empty feeds resolve to `.upToDate`
/// so a flaky connection never blocks a first launch.
enum OnboardingUpdateCheck {

    enum Result {
        /// Either no newer version, or we couldn't reach the feed.
        /// In both cases the caller proceeds straight to onboarding.
        case upToDate
        /// Feed reports a newer `shortVersionString` than what's
        /// running. Caller should prompt the user.
        case updateAvailable(latest: String)
    }

    /// Probe the appcast and call `completion` on the main queue with
    /// the comparison result. Honours a 3-second timeout — we want the
    /// onboarding launch path to be snappy, and a slow feed shouldn't
    /// hold up the welcome screen.
    static func check(
        feedURL: URL,
        currentVersion: String,
        timeout: TimeInterval = 3,
        completion: @escaping (Result) -> Void
    ) {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            let result: Result
            if let data, let latest = parseLatestVersion(from: data),
               versionIsNewer(latest, than: currentVersion) {
                result = .updateAvailable(latest: latest)
            } else {
                result = .upToDate
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }

    /// Extract the newest `<sparkle:shortVersionString>` from an
    /// appcast feed. Items are expected newest-first per Sparkle
    /// convention (and our own workflow inserts at the top), so we
    /// take the first item we find rather than walking the whole list
    /// and sorting.
    static func parseLatestVersion(from data: Data) -> String? {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data)
        } catch {
            return nil
        }
        guard let root = doc.rootElement(),
              let channel = root.elements(forName: "channel").first,
              let firstItem = channel.elements(forName: "item").first else {
            return nil
        }
        // ElementTree on the server side writes the prefixed form
        // (`sparkle:shortVersionString`). NSXMLDocument keeps the
        // prefix on the element name, so `elements(forName:)` matches
        // by the full QName.
        let versionEl = firstItem.elements(forName: "sparkle:shortVersionString").first
        return versionEl?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Semantic-ish version compare. Splits on `.`, treats each part as
    /// an integer (non-numeric → 0), longer-with-non-zero tail wins.
    /// Good enough for our `MAJOR.MINOR.PATCH` versioning; we never
    /// ship pre-release tags like `0.8.0-beta`.
    static func versionIsNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        let len = max(a.count, b.count)
        for i in 0..<len {
            let lhs = i < a.count ? a[i] : 0
            let rhs = i < b.count ? b[i] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
