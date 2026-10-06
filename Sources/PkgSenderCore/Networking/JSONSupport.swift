import Foundation

/// Minimal JSON string/number helpers.
///
/// The receiver answers with a handful of flat JSON documents and — depending
/// on the payload version — sometimes with plain HTML. A real parser would
/// throw on the HTML case, so the fields we need are read positionally instead.
public enum JSONText {
    /// Full escaping including control characters: titles come from PKG SFO
    /// data and must not be able to break the JSON we serve.
    public static func escape(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\"": out.append(contentsOf: "\\\"".unicodeScalars)
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16, uppercase: false)
                    out.append(contentsOf: "\\u".unicodeScalars)
                    out.append(contentsOf: String(repeating: "0", count: max(0, 4 - hex.count)).unicodeScalars)
                    out.append(contentsOf: hex.unicodeScalars)
                } else {
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }

    /// RPI-style escaping: newlines become spaces so a single broken field
    /// cannot corrupt the whole install request.
    public static func escapeForConsole(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

/// Reads scalar fields out of the flat JSON documents the receiver returns.
public enum JSONScalarReader {
    /// Value of `"key":"…"`, or `""` when absent.
    public static func string(_ body: String, key: String) -> String {
        let pattern = "\"\(key)\":\""
        guard let start = body.range(of: pattern) else { return "" }
        let rest = body[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return "" }
        return String(rest[rest.startIndex..<end])
    }

    /// Value of `"key":<int>`, or `nil` when absent/unparsable.
    public static func integer(_ body: String, key: String) -> Int64? {
        let pattern = "\"\(key)\":"
        guard let start = body.range(of: pattern) else { return nil }
        let rest = body[start.upperBound...]
        var end = rest.startIndex
        while end < rest.endIndex, rest[end].isASCII, rest[end].isNumber || rest[end] == "-" {
            end = rest.index(after: end)
        }
        guard end > rest.startIndex else { return nil }
        return Int64(rest[rest.startIndex..<end])
    }

    /// True when the document contains `"key":true` (tolerating whitespace).
    public static func bool(_ body: String, key: String) -> Bool {
        let collapsed = body.filter { !$0.isWhitespace }
        return collapsed.contains("\"\(key)\":true")
    }
}
