import Foundation

/// Stable identifiers for library rows.
///
/// A file path is not usable as a SwiftUI `Identifiable` id: it is long, its
/// case-folding differs per volume and it may contain characters the UI layer
/// treats specially. FNV-1a is used instead because it is dependency-free and
/// gives the same answer in every process — `Hasher` is seeded per process, so
/// a hash-based id would reshuffle the whole list on every launch.
public enum StableID {
    /// Id for a file or folder path. Same path -> same id, always.
    public static func forPath(_ path: String) -> String {
        hex(fnv1a64(path))
    }

    /// Id for a title: prefers the title id, falls back to the content id so
    /// an update and its base game can be recognised across renames.
    public static func forContent(titleId: String, contentId: String) -> String {
        let tid = titleId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tid.isEmpty { return "tid-" + hex(fnv1a64(tid)) }
        let cid = contentId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cid.isEmpty { return "cid-" + hex(fnv1a64(cid)) }
        return "none"
    }

    /// FNV-1a, 64 bit. Pure function: same input, same output, no seeding.
    public static func fnv1a64(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }

    /// Lowercase 16-digit hex, zero padded so ids sort and compare uniformly.
    public static func hex(_ value: UInt64) -> String {
        let text = String(value, radix: 16)
        guard text.count < 16 else { return text }
        return String(repeating: "0", count: 16 - text.count) + text
    }
}
