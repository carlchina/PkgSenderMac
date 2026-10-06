import Foundation

/// One `key = value` pair from a package's metadata, for the detail view.
public struct PkgParam: Hashable, Sendable, Codable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// What a package reader managed to learn about one file.
///
/// Every field is optional-by-empty rather than nil: a partially parsed
/// package is still sendable, and the senders move raw bytes — they never
/// depend on parsing having succeeded.
public struct PkgInfo: Hashable, Sendable {
    public var title: String
    public var contentId: String
    public var titleId: String
    public var contentType: String
    public var version: String
    public var isDLC: Bool
    public var platform: String
    public var description: String
    public var packageSize: Int64
    /// `pkg` | `exfat` | `ffpfsc` | `ffpkg` | `folder`.
    public var format: String
    public var isFolder: Bool
    /// PKG header digest: 32 bytes at CNT+0xFE0, uppercase hex.
    /// The BGFT manifest on the console needs the real value, so it is
    /// carried through rather than recomputed.
    public var digest: String
    public var iconData: Data?
    public var params: [PkgParam]

    public init(
        title: String = "",
        contentId: String = "",
        titleId: String = "",
        contentType: String = "",
        version: String = "",
        isDLC: Bool = false,
        platform: String = "",
        description: String = "",
        packageSize: Int64 = 0,
        format: String = "pkg",
        isFolder: Bool = false,
        digest: String = "",
        iconData: Data? = nil,
        params: [PkgParam] = []
    ) {
        self.title = title
        self.contentId = contentId
        self.titleId = titleId
        self.contentType = contentType
        self.version = version
        self.isDLC = isDLC
        self.platform = platform
        self.description = description
        self.packageSize = packageSize
        self.format = format
        self.isFolder = isFolder
        self.digest = digest
        self.iconData = iconData
        self.params = params
    }

    /// True when the reader learned nothing that identifies the content —
    /// callers use this to decide whether to fall back to another reader.
    public var isEmpty: Bool { title.isEmpty && contentId.isEmpty }
}
