import Foundation

/// Human-readable byte sizes.
///
/// Binary units (KiB = 1024 B) match the console's own reporting, so a size
/// shown here matches what the PS5 later displays for the same package.
/// Formatting is locale-independent on purpose: the string is also used to
/// build filenames and cache keys.
public enum SizeFormatter {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    /// `0` -> "0 B", `1536` -> "1.50 KB", `4_294_967_296` -> "4.00 GB".
    /// Negative values (unknown size) render as "—".
    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else { return bytes == 0 ? "0 B" : "—" }
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: "%.2f %@", value, units[unit])
    }

    /// Exact byte count with thousands separators — used where the precise
    /// size matters (folder totals). Grouped by hand rather than through
    /// `NumberFormatter`, so the output cannot shift with the user's locale.
    public static func exact(_ bytes: Int64) -> String {
        guard bytes >= 0 else { return "—" }
        let digits = String(bytes)
        var out = ""
        out.reserveCapacity(digits.count + digits.count / 3 + 2)
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return out + " B"
    }
}
