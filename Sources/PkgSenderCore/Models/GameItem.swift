import Foundation

/// Which member of a title family a row is.
///
/// PS5 packages carry no category flag, so the role is derived from the
/// package format and (for PS4) from `param.sfo`'s CATEGORY. The raw values
/// are kept identical to the upstream C# UI so a library exported by either
/// app reads the same.
public enum GameRole: String, Codable, Hashable, Sendable, CaseIterable {
    case game = "Game"
    case patch = "Patch"
    case dlc = "DLC"
    case image = "Image"

    /// Sort order inside a family: base game first, then updates, DLC, images.
    public var rank: Int {
        switch self {
        case .game: return 0
        case .patch: return 1
        case .dlc: return 2
        case .image: return 3
        }
    }
}

/// One row of the library: a package, a disk image or a dumped app folder.
///
/// The struct is a plain value so it can cross threads freely (scanning runs
/// off the main thread) and be cached as JSON. `iconData` is embedded rather
/// than referenced by path: the cover has to survive the source file being
/// moved to another volume, and these are 8-bit PNGs of a few hundred KB.
public struct GameItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var path: String
    public var title: String
    public var contentId: String
    public var titleId: String
    public var contentType: String
    public var version: String
    public var platform: String
    /// `pkg` | `exfat` | `ffpfsc` | `ffpkg` | `folder`.
    public var format: String
    public var sizeBytes: Int64
    public var iconData: Data?
    /// PKG header digest, uppercase hex (32 bytes at CNT+0xFE0).
    /// Empty for formats that have no CNT header (images, folders).
    public var digest: String
    public var role: GameRole
    public var familyKey: String
    public var isFolder: Bool
    /// One-line subtitle for the card (`CUSA00001 • v1.06 • Patch`).
    public var meta: String
    /// Set by `LibraryScanner` in a second pass: >1 members of one family.
    public var familyCount: Int
    public var hasFamily: Bool
    public var familyTip: String

    public init(
        path: String,
        title: String,
        contentId: String = "",
        titleId: String = "",
        contentType: String = "",
        version: String = "",
        platform: String = "",
        format: String = "pkg",
        sizeBytes: Int64 = 0,
        iconData: Data? = nil,
        digest: String = "",
        role: GameRole = .game,
        familyKey: String? = nil,
        isFolder: Bool = false,
        meta: String? = nil
    ) {
        self.id = StableID.forPath(path)
        self.path = path
        self.title = title
        self.contentId = contentId
        self.titleId = titleId
        self.contentType = contentType
        self.version = version
        self.platform = platform
        self.format = format
        self.sizeBytes = sizeBytes
        self.iconData = iconData
        self.digest = digest
        self.role = role
        self.familyKey = familyKey ?? Self.makeFamilyKey(titleId: titleId, path: path)
        self.isFolder = isFolder
        self.meta = meta ?? Self.makeMeta(id: titleId.isEmpty ? contentId : titleId,
                                          version: version,
                                          role: role)
        self.familyCount = 0
        self.hasFamily = false
        self.familyTip = ""
    }

    /// Build a row from parsed package metadata.
    public init(path: String, info: PkgInfo) {
        let fmt = info.format.isEmpty ? "pkg" : info.format
        let role = Self.makeRole(format: fmt, isDLC: info.isDLC, contentType: info.contentType)
        let title = info.title.isEmpty ? (path as NSString).lastPathComponent : info.title
        self.init(
            path: path,
            title: title,
            contentId: info.contentId,
            titleId: info.titleId,
            contentType: info.contentType,
            version: Self.cleanVersion(info.version),
            platform: Self.makePlatform(info: info, format: fmt),
            format: fmt,
            sizeBytes: info.packageSize,
            iconData: info.iconData,
            digest: info.digest,
            role: role,
            isFolder: info.isFolder
        )
    }

    // MARK: - Derived

    public var hasCover: Bool { (iconData?.count ?? 0) > 0 }
    public var isImage: Bool { role == .image }
    public var isPS5: Bool { platform.hasPrefix("PS5") }
    public var isPS4: Bool { platform.hasPrefix("PS4") }
    public var isDLC: Bool { role == .dlc }
    public var sizeText: String { SizeFormatter.string(sizeBytes) }
    public var fileName: String { (path as NSString).lastPathComponent }

    /// Lowercased search haystack. Filtering thousands of rows per keystroke
    /// must not re-lowercase the whole library on every character.
    public var searchHaystack: String {
        "\(title)\n\(contentId)\n\(familyKey)\n\(fileName)".lowercased()
    }

    // MARK: - Helpers

    /// `pkg` files are games/updates/DLC; every other container format is an
    /// image that the console mounts rather than installs.
    public static func makeRole(format: String, isDLC: Bool, contentType: String) -> GameRole {
        guard format == "pkg" else { return .image }
        if isDLC { return .dlc }
        // PS4 updates: CATEGORY "gp".
        if contentType.caseInsensitiveCompare("gp") == .orderedSame { return .patch }
        return .game
    }

    /// Family key: the exact title id, so region variants stay separate.
    /// Without a title id a row is its own family — never merge by title
    /// text, which would glue unrelated games with similar names together.
    public static func makeFamilyKey(titleId: String, path: String) -> String {
        let tid = titleId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if tid.count >= 4 { return tid }
        return "FILE:" + ((path as NSString).lastPathComponent).uppercased()
    }

    /// `1.06`, not `v1.06` — the version column prefixes its own "v".
    public static func cleanVersion(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    private static func makePlatform(info: PkgInfo, format: String) -> String {
        let base = info.platform.isEmpty ? "PS5" : info.platform
        guard format == "pkg" else { return "\(base) • \(format)" }
        return info.platform.isEmpty ? "PKG" : info.platform
    }

    private static func makeMeta(id: String, version: String, role: GameRole) -> String {
        var parts: [String] = []
        if !id.isEmpty { parts.append(id) }
        let v = cleanVersion(version)
        if !v.isEmpty { parts.append("v" + v) }
        if role != .game { parts.append(role.rawValue) }
        return parts.joined(separator: " • ")
    }
}
