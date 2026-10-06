import Foundation

/// Bounds-checked reader over a fixed byte buffer.
///
/// `Data.subdata(in:)` **traps** on an out-of-range range rather than
/// returning nil, and `Data`'s integer subscript does the same. Every
/// accessor here validates its range first and returns nil so a malformed
/// package can never take the process down mid-scan — the parsers are handed
/// attacker-shaped files (downloads, dumps of unknown provenance) and must
/// degrade to "unreadable", not crash.
public struct ByteReader: Sendable, Hashable {
    public let bytes: [UInt8]

    public init(_ data: Data) { self.bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var count: Int { bytes.count }

    /// Single range check shared by every accessor. Written as
    /// `n <= count - offset` so an offset beyond the end yields a negative
    /// bound instead of an overflowed `offset + n`.
    @inline(__always)
    private func has(_ offset: Int, _ n: Int) -> Bool {
        offset >= 0 && n >= 0 && n <= bytes.count - offset
    }

    public func u8(at offset: Int) -> UInt8? {
        has(offset, 1) ? bytes[offset] : nil
    }

    public func u16le(at offset: Int) -> UInt16? {
        guard has(offset, 2) else { return nil }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public func u16be(at offset: Int) -> UInt16? {
        guard has(offset, 2) else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    public func u32le(at offset: Int) -> UInt32? {
        guard has(offset, 4) else { return nil }
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = (v << 8) | UInt32(bytes[offset + i]) }
        return v
    }

    public func u32be(at offset: Int) -> UInt32? {
        guard has(offset, 4) else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(bytes[offset + i]) }
        return v
    }

    public func u64le(at offset: Int) -> UInt64? {
        guard has(offset, 8) else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(bytes[offset + i]) }
        return v
    }

    public func u64be(at offset: Int) -> UInt64? {
        guard has(offset, 8) else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(bytes[offset + i]) }
        return v
    }

    /// Raw slice; nil when the range leaves the buffer.
    public func bytes(at offset: Int, count n: Int) -> [UInt8]? {
        guard has(offset, n) else { return nil }
        return Array(bytes[offset..<(offset + n)])
    }

    public func data(at offset: Int, count n: Int) -> Data? {
        guard let slice = bytes(at: offset, count: n) else { return nil }
        return Data(slice)
    }

    /// ASCII string ending at the first NUL inside a fixed-width field.
    /// Nil when the field itself is out of bounds.
    public func fixedString(at offset: Int, length: Int) -> String? {
        guard let raw = bytes(at: offset, count: length) else { return nil }
        let end = raw.firstIndex(of: 0) ?? raw.count
        return String(decoding: raw[..<end], as: UTF8.self)
    }

    /// Fixed-width field with its NUL padding trimmed from both ends.
    public func paddedString(at offset: Int, length: Int) -> String? {
        guard let raw = bytes(at: offset, count: length) else { return nil }
        let trimmed = raw.filter { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// NUL-terminated string starting at `offset`, read at most `limit` bytes.
    /// Returns nil when `offset` is outside the buffer; an unterminated
    /// string is clipped to the buffer end rather than rejected.
    public func cString(at offset: Int, limit: Int) -> String? {
        guard offset >= 0, offset < bytes.count, limit >= 0 else { return nil }
        let end = min(bytes.count, offset + limit)
        var i = offset
        while i < end, bytes[i] != 0 { i += 1 }
        return String(decoding: bytes[offset..<i], as: UTF8.self)
    }
}

/// Errors raised while parsing a package. Purely diagnostic: every caller
/// treats a throw as "not a package I understand" and falls back to the next
/// reader, so none of these ever surface to the user.
public enum PkgParseError: Error, Hashable, Sendable, LocalizedError {
    case tooSmall
    case badMagic
    case badHeader
    case badEntry
    case outOfBounds

    public var errorDescription: String? {
        switch self {
        case .tooSmall: return "file is too small to hold a header"
        case .badMagic: return "unrecognised container magic"
        case .badHeader: return "malformed container header"
        case .badEntry: return "malformed entry table"
        case .outOfBounds: return "read past end of file"
        }
    }
}
