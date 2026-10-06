import Foundation

public enum RangeSourceError: Error, Sendable, LocalizedError {
    case cannotOpen(String)
    case cannotSeek(String)
    case offsetOutOfRange(Int64)

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let path): return "cannot open \(path)"
        case .cannotSeek(let path): return "cannot seek in \(path)"
        case .offsetOutOfRange(let offset): return "offset \(offset) outside of range source"
        }
    }
}

/// Sequential byte reader handed out by a `RangeSource`.
///
/// One reader per connection: it owns the file descriptor it reads from and
/// must be closed by the caller.
public final class RangeByteReader {
    private let readImpl: (Int) throws -> Data?
    private let closeImpl: () -> Void
    private var isClosed = false

    public init(read: @escaping (Int) throws -> Data?, close: @escaping () -> Void = {}) {
        readImpl = read
        closeImpl = close
    }

    /// Next chunk, `nil` at end of data.
    public func read(upToCount count: Int) throws -> Data? {
        try readImpl(max(1, count))
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        closeImpl()
    }

    deinit { close() }
}

/// Seekable byte source for direct (no-copy) serving — a whole file, a slice
/// of one, or any external document.
///
/// `open(at:)` must return an independent reader positioned at `offset` so
/// concurrent connections never share a file offset.
public final class RangeSource: @unchecked Sendable {
    public let length: Int64
    private let openImpl: (Int64) throws -> RangeByteReader

    public init(length: Int64, open: @escaping (Int64) throws -> RangeByteReader) {
        self.length = length
        openImpl = open
    }

    public func open(at offset: Int64) throws -> RangeByteReader {
        try openImpl(offset)
    }
}

public extension RangeSource {
    /// Whole file served directly from disk.
    convenience init?(fileAtPath path: String) {
        guard let size = RangeSource.sizeOfFile(at: path) else { return nil }
        self.init(length: size) { offset in
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            do {
                try handle.seek(toOffset: UInt64(offset))
            } catch {
                try? handle.close()
                throw RangeSourceError.cannotSeek(path)
            }
            return RangeByteReader(
                read: { try handle.read(upToCount: $0) },
                close: { try? handle.close() }
            )
        }
    }

    /// Byte range of a file served as its own resource (parallel piece).
    convenience init?(fileAtPath path: String, sliceOffset: Int64, sliceLength: Int64) {
        guard sliceOffset >= 0, sliceLength >= 0,
              let size = RangeSource.sizeOfFile(at: path),
              sliceOffset + sliceLength <= size else { return nil }
        self.init(length: sliceLength) { offset in
            guard offset >= 0, offset <= sliceLength else {
                throw RangeSourceError.offsetOutOfRange(offset)
            }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            do {
                try handle.seek(toOffset: UInt64(sliceOffset + offset))
            } catch {
                try? handle.close()
                throw RangeSourceError.cannotSeek(path)
            }
            var remaining = sliceLength - offset
            return RangeByteReader(
                read: { count in
                    guard remaining > 0 else { return nil }
                    guard let chunk = try handle.read(upToCount: min(count, Int(remaining))),
                          !chunk.isEmpty else { return nil }
                    remaining -= Int64(chunk.count)
                    return chunk
                },
                close: { try? handle.close() }
            )
        }
    }

    static func sizeOfFile(at path: String) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }
}

/// One row of the console browser catalog served at `GET /catalog`.
public struct CatalogEntry: Sendable, Hashable {
    public var id: String
    public var title: String
    public var titleId: String
    public var version: String
    public var size: Int64
    public var sizeText: String
    /// `Game | Patch | DLC | Image`
    public var role: String
    public var familyKey: String
    public var platform: String
    /// `pkg | exfat | ffpfsc | ffpkg`
    public var format: String
    /// Basename, used by copy-to-console.
    public var file: String
    public var hasIcon: Bool

    public init(
        id: String = "",
        title: String = "",
        titleId: String = "",
        version: String = "",
        size: Int64 = 0,
        sizeText: String = "",
        role: String = "Game",
        familyKey: String = "",
        platform: String = "",
        format: String = "pkg",
        file: String = "",
        hasIcon: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleId = titleId
        self.version = version
        self.size = size
        self.sizeText = sizeText
        self.role = role
        self.familyKey = familyKey
        self.platform = platform
        self.format = format
        self.file = file
        self.hasIcon = hasIcon
    }
}

/// Serializer for `GET /catalog`.
public enum CatalogJSON {
    public static func text(_ entries: [CatalogEntry]) -> String {
        var rows: [String] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            rows.append(
                "{\"id\":\"" + JSONText.escape(entry.id) + "\""
                    + ",\"title\":\"" + JSONText.escape(entry.title) + "\""
                    + ",\"titleId\":\"" + JSONText.escape(entry.titleId) + "\""
                    + ",\"version\":\"" + JSONText.escape(entry.version) + "\""
                    + ",\"size\":" + String(entry.size)
                    + ",\"sizeText\":\"" + JSONText.escape(entry.sizeText) + "\""
                    + ",\"role\":\"" + JSONText.escape(entry.role) + "\""
                    + ",\"familyKey\":\"" + JSONText.escape(entry.familyKey) + "\""
                    + ",\"platform\":\"" + JSONText.escape(entry.platform) + "\""
                    + ",\"format\":\"" + JSONText.escape(entry.format) + "\""
                    + ",\"file\":\"" + JSONText.escape(entry.file) + "\""
                    + ",\"hasIcon\":" + (entry.hasIcon ? "true" : "false")
                    + "}"
            )
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    public static func data(_ entries: [CatalogEntry]) -> Data {
        Data(text(entries).utf8)
    }
}
