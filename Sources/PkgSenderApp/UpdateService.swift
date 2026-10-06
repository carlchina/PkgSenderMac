import Foundation

/// Lightweight auto-update for the macOS port: a GitHub Releases *silent*
/// check plus an "update available" affordance that opens the release page.
///
/// No Sparkle, no EdDSA signing — this fits the ad-hoc, un-notarized build
/// (Sparkle would refuse to install unsigned updates anyway). The check
/// compares the latest release `tag_name` against `appVersion`; on a newer
/// tag it flips `updateAvailable` and remembers the release URL.
///
/// Point it at any repo with the `PKGSENDER_UPDATE_REPO` environment variable
/// (`owner/name`), so the macOS build can track a fork (e.g.
/// `carlchina/PkgSenderMac`) instead of the upstream .NET repo, whose
/// releases carry only Windows/Linux assets.
enum UpdateService {
    /// Kept in sync with the release tag.
    static let appVersion = "v1.0.0"

    /// `owner/name` of the repo to watch. Override via the
    /// `PKGSENDER_UPDATE_REPO` environment variable.
    static var repository: String {
        ProcessInfo.processInfo.environment["PKGSENDER_UPDATE_REPO"]
            ?? "carlchina/PkgSenderMac"
    }

    /// Outcome of a check. Network/parse failures return `available: false`
    /// with the reason in `error`, so callers can stay silent rather than
    /// nagging offline (or rate-limited) users.
    struct UpdateInfo: Sendable {
        let available: Bool
        let latestVersion: String
        let releaseURL: URL?
        let notes: String?
        let error: String?
    }

    /// Query the latest GitHub release and compare versions.
    ///
    /// Never throws: failures are reported through `UpdateInfo.error` so a
    /// flaky network never surfaces as an alert.
    static func checkForUpdate() async -> UpdateInfo {
        let repo = Self.repository
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return UpdateInfo(available: false, latestVersion: "", releaseURL: nil,
                              notes: nil, error: "bad repo")
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub requires a User-Agent header; identify ourselves clearly.
        request.setValue("PkgSenderMac/\(appVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse,
               http.statusCode == 403 || http.statusCode == 429 {
                // Rate-limited (unauthenticated: 60 req/hr/IP) — stay silent.
                return UpdateInfo(available: false, latestVersion: "", releaseURL: nil,
                                  notes: nil, error: "rate-limited")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return UpdateInfo(available: false, latestVersion: "", releaseURL: nil,
                                  notes: nil, error: "no tag")
            }
            let html = (json["html_url"] as? String).flatMap { URL(string: $0) }
            let notes = json["body"] as? String
            let newer = isNewer(latest: tag, current: appVersion)
            return UpdateInfo(available: newer, latestVersion: tag,
                              releaseURL: html, notes: notes, error: nil)
        } catch {
            return UpdateInfo(available: false, latestVersion: "", releaseURL: nil,
                              notes: nil, error: error.localizedDescription)
        }
    }

    /// `true` when `latest` is strictly newer than `current`. Both may carry a
    /// leading "v". Non-numeric or empty segments compare as 0.
    static func isNewer(latest: String, current: String) -> Bool {
        let a = normalize(latest)
        let b = normalize(current)
        guard !a.isEmpty else { return false }
        let az = a.split(separator: ".", omittingEmptySubsequences: false)
        let bz = b.split(separator: ".", omittingEmptySubsequences: false)
        let count = max(az.count, bz.count)
        for i in 0..<count {
            let lv = Int(az.count > i ? String(az[i]) : "0") ?? 0
            let cv = Int(bz.count > i ? String(bz[i]) : "0") ?? 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    private static func normalize(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("v") { s.removeFirst() }
        return s
    }
}
