import Foundation

/// A single `param.sfo` value.
///
/// The original type is kept so an int32 entry (SYSTEM_VER, ATTRIBUTE) can be
/// rendered as hex, which is what the upstream tools print — converting
/// everything to text up front would turn `0x05010000` into `83886080`.
public enum SFOValue: Hashable, Sendable {
    case text(String)
    case int(UInt32)

    /// Text for display; ints become uppercase 8-digit hex.
    public var text: String {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(format: "%08X", v)
        }
    }

    public var stringValue: String {
        if case .text(let s) = self { return s }
        return ""
    }
}

/// Minimal `param.sfo` reader (PS3/PS4/PS5 metadata blob).
///
/// Only the two formats that actually occur are decoded: UTF-8 strings
/// (0x0204) and int32 (0x0404). Anything else is skipped rather than
/// aborting — a single unknown entry must not cost us the whole package,
/// which is exactly how a library scan would silently drop a game.
public enum SFO {
    /// Entry count cap. Real packages carry a few dozen keys; a huge count
    /// means a corrupt header, and walking it would allocate wildly.
    private static let maxEntries = 4096

    public static func parse(_ data: Data) throws -> [String: SFOValue] {
        let r = ByteReader(data)
        guard data.count >= 0x14 else { throw PkgParseError.tooSmall }
        // Magic is "\0PSF": compare raw bytes, because a NUL-trimming helper
        // would drop the leading zero byte and never match.
        guard let magic = r.bytes(at: 0, count: 4), magic == [0x00, 0x50, 0x53, 0x46] else {
            throw PkgParseError.badMagic
        }
        guard let keyTable = r.u32le(at: 0x08),
              let dataTable = r.u32le(at: 0x0C),
              let count = r.u32le(at: 0x10) else {
            throw PkgParseError.badHeader
        }
        guard count <= maxEntries else { throw PkgParseError.badHeader }
        let keyBase = Int(keyTable), dataBase = Int(dataTable)
        guard keyBase >= 0, keyBase <= data.count, dataBase >= 0, dataBase <= data.count else {
            throw PkgParseError.badHeader
        }

        var out: [String: SFOValue] = [:]
        for i in 0..<Int(count) {
            let entry = 0x14 + i * 0x10
            guard let keyOffset = r.u16le(at: entry),
                  let format = r.u16le(at: entry + 2),
                  let maxLength = r.u32le(at: entry + 8),
                  let valueOffset = r.u32le(at: entry + 12) else {
                break           // truncated table: stop, keep what we have
            }
            let keyStart = keyBase + Int(keyOffset)
            guard let key = r.cString(at: keyStart, limit: min(256, max(0, data.count - keyStart))),
                  !key.isEmpty else { continue }

            let valueStart = dataBase + Int(valueOffset)
            guard valueStart >= 0, valueStart <= data.count else { continue }
            let usable = min(Int(maxLength), max(0, data.count - valueStart))

            switch format {
            case 0x0204:        // UTF-8, NUL padded
                let slice = r.bytes(at: valueStart, count: usable) ?? []
                let end = slice.firstIndex(of: 0) ?? slice.count
                let text = String(decoding: slice[..<end], as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                out[key] = .text(text)
            case 0x0404:        // int32
                if let v = r.u32le(at: valueStart) { out[key] = .int(v) }
            default:
                continue        // binary / unknown: skip, do not abort
            }
        }
        return out
    }

    /// Convenience: text value of a key, "" when absent or not text.
    public static func string(_ dict: [String: SFOValue], _ key: String) -> String {
        dict[key]?.stringValue ?? ""
    }
}
