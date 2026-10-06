import Foundation

/// Percent-encoding helpers shared by the console client, the local range
/// server and the PS4 installer.
///
/// The receiver on the console decodes every URL we hand it exactly once, so
/// every URL crossing the wire has to be encoded exactly once as well. Encoding
/// an already-encoded URL would turn `%` into `%25` and break the install
/// (upstream issue #6); encoding none at all breaks on spaces.
public enum URLEncoding {
    /// RFC 3986 unreserved characters — everything else is percent-encoded.
    public static func unreservedCharacters() -> CharacterSet {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        set.insert(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        set.insert(charactersIn: "0123456789")
        set.insert(charactersIn: "-._~")
        return set
    }

    /// Percent-encode a raw (never encoded) string.
    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters()) ?? value
    }

    /// Percent-encode exactly once: decoding first makes the operation
    /// idempotent, so both raw and already-encoded input come out valid.
    public static func encodeOnce(_ value: String) -> String {
        encode(value.removingPercentEncoding ?? value)
    }

    /// Percent-encode a single path component (`/pkg/{id}`, `/icon/{id}`).
    public static func encodePathComponent(_ value: String) -> String {
        encodeOnce(value)
    }

    /// Percent-encode a query value (`?path=…`).
    public static func encodeQueryValue(_ value: String) -> String {
        encode(value)
    }

    /// Inverse of `encode(_:)`; returns the input when it is not valid
    /// percent-encoding (the console/receiver tolerate that too).
    public static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }
}
