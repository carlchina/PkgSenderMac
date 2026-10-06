import Foundation

/// Metadata pulled from a PS5 `param.json`.
public struct ParamJSONMeta: Hashable, Sendable {
    public var title: String
    public var titleId: String
    public var contentId: String
    public var version: String

    public init(title: String = "", titleId: String = "",
                contentId: String = "", version: String = "") {
        self.title = title
        self.titleId = titleId
        self.contentId = contentId
        self.version = version
    }
}

/// PS5 `param.json` reader.
///
/// Titles are localised: the file holds a `localizedParameters` map with one
/// entry per language. `defaultLanguage` decides which one is shown, with a
/// fallback to whatever entry carries a title (a dump with only `ja-JP`
/// would otherwise render as an empty card).
public enum ParamJSON {
    /// Cap on the JSON we are willing to parse. param.json is a few KB; a
    /// larger blob means we read the wrong entry.
    public static let maxBytes = 2 * 1024 * 1024

    public static func parse(_ data: Data) -> ParamJSONMeta? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else { return nil }
        return parse(dict)
    }

    public static func parse(_ dict: [String: Any]) -> ParamJSONMeta {
        var meta = ParamJSONMeta()
        meta.titleId = dict["titleId"] as? String ?? ""
        meta.contentId = dict["contentId"] as? String ?? ""
        meta.version = dict["contentVersion"] as? String ?? ""
        meta.title = localizedTitle(dict)
        return meta
    }

    public static func localizedTitle(_ dict: [String: Any]) -> String {
        guard let lp = dict["localizedParameters"] as? [String: Any] else { return "" }
        let lang = lp["defaultLanguage"] as? String ?? "en-US"
        if let entry = lp[lang] as? [String: Any], let t = entry["titleName"] as? String,
           !t.isEmpty {
            return t
        }
        // Fall back to any locale that carries a title.
        for (_, value) in lp {
            if let entry = value as? [String: Any],
               let t = entry["titleName"] as? String, !t.isEmpty {
                return t
            }
        }
        return ""
    }
}
