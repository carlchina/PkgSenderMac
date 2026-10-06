import Foundation

/// Persisted application settings (`~/Library/Application Support/PkgSender/settings.json`).
///
/// Every field has a non-absurd default, and `normalized()` clamps anything
/// loaded from disk: a hand-edited or half-written JSON file must never be
/// able to put the app into a state it cannot recover from (a 0-byte chunk
/// size would hang a transfer, an empty remote dir would push to `/`).
public struct AppSettings: Codable, Hashable, Sendable {
    /// Console address the payload and transfers talk to.
    public var psIP: String
    /// Local interface the console connects back to.
    public var pcIP: String
    /// Destination directory on the console.
    public var remoteDir: String
    /// Transfer chunk size in bytes.
    public var chunkSize: Int
    public var updateCheck: Bool
    public var aboutShown: Bool
    /// Library scan roots, kept here so a relaunch restores the shelf.
    public var libraryRoots: [String]

    public static let defaultChunkSize = 2 * 1024 * 1024
    public static let chunkSizeRange = 64 * 1024...(64 * 1024 * 1024)

    public init(
        psIP: String = "192.168.1.105",
        pcIP: String = "192.168.1.100",
        remoteDir: String = "/data/homebrew",
        chunkSize: Int = defaultChunkSize,
        updateCheck: Bool = true,
        aboutShown: Bool = false,
        libraryRoots: [String] = []
    ) {
        self.psIP = psIP
        self.pcIP = pcIP
        self.remoteDir = remoteDir
        self.chunkSize = chunkSize
        self.updateCheck = updateCheck
        self.aboutShown = aboutShown
        self.libraryRoots = libraryRoots
    }

    /// Trimmed and clamped copy — applied on load and before every save.
    public var normalized: AppSettings {
        var s = self
        s.psIP = s.psIP.trimmingCharacters(in: .whitespacesAndNewlines)
        s.pcIP = s.pcIP.trimmingCharacters(in: .whitespacesAndNewlines)
        var dir = s.remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if dir.isEmpty { dir = "/data/homebrew" }
        if !dir.hasPrefix("/") { dir = "/" + dir }
        // Collapse "//" and strip a trailing slash: "/data/homebrew/" and
        // "/data/homebrew" are the same directory on the console.
        while dir.contains("//") { dir = dir.replacingOccurrences(of: "//", with: "/") }
        if dir.count > 1, dir.hasSuffix("/") { dir.removeLast() }
        s.remoteDir = dir
        s.chunkSize = min(max(s.chunkSize, Self.chunkSizeRange.lowerBound),
                          Self.chunkSizeRange.upperBound)
        s.libraryRoots = s.libraryRoots
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return s
    }

    /// Very rough IPv4 sanity check — enough to warn before a transfer is
    /// started against a typo, not a substitute for reaching the console.
    public static func looksLikeIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isNumber), let v = Int(p), v >= 0, v <= 255 else {
                return false
            }
        }
        return true
    }

    public var psIPLooksValid: Bool { Self.looksLikeIPv4(psIP) }
    public var pcIPLooksValid: Bool { Self.looksLikeIPv4(pcIP) }
}
