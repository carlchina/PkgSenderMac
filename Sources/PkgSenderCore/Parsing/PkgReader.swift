import Foundation

/// Reads package metadata: PS4 (`param.sfo`), PS5 (`param.json`), cover art
/// and the header digest.
///
/// PS4 is tried first because a PS4 package's CNT also carries a content id
/// but no `param.json`; a PS5 package has no `param.sfo`. Whichever reader
/// produces identity wins, and a package that yields nothing from either is
/// reported as nil so the caller can fall back to a filename stub.
public enum PkgReader {
    /// Digest as the console wants it: 32 bytes at CNT+0xFE0, uppercase hex.
    public static func read(url: URL) -> PkgInfo? {
        guard let source = FileByteSource(url: url) else { return nil }
        return read(source, name: url.lastPathComponent)
    }

    public static func read(_ source: any ByteSource, name: String = "") -> PkgInfo? {
        if let ps4 = readPS4(source, name: name), !ps4.isEmpty { return ps4 }
        return readPS5(source, name: name)
    }

    // MARK: PS4 — param.sfo inside a bare CNT

    static func readPS4(_ source: any ByteSource, name: String = "") -> PkgInfo? {
        guard let cnt = CntImage.open(source) else { return nil }

        // Legacy PS4 `\x7FPKG`: no resolvable param.sfo entry, so build a
        // best-effort row from the header content id + digest.
        guard !cnt.isPKG else {
            var contentId = cnt.contentId
            var titleId = Self.titleIdFromContentId(contentId)
            var title = contentId.isEmpty ? name : contentId
            guard !title.isEmpty || !contentId.isEmpty else { return nil }
            var params: [PkgParam] = []
            if !titleId.isEmpty { params.append(PkgParam("TITLE_ID", titleId)) }
            if !contentId.isEmpty { params.append(PkgParam("CONTENT_ID", contentId)) }
            return PkgInfo(
                title: title,
                contentId: contentId,
                titleId: titleId,
                platform: "PS4",
                description: "[PS4] \(title)",
                packageSize: source.byteCount,
                format: "pkg",
                digest: cnt.digest,
                params: params
            )
        }

        // CNT/FIH: a real param.sfo is required to call this PS4.
        guard let sfoEntry = cnt.find(id: CntImage.paramSfoId, name: "param.sfo"),
              let sfoData = Optional(cnt.readEntry(sfoEntry, cap: 1024 * 1024)),
              !sfoData.isEmpty,
              let sfo = try? SFO.parse(sfoData) else { return nil }

        let title = SFO.string(sfo, "TITLE")
        let contentId = SFO.string(sfo, "CONTENT_ID")
        guard !title.isEmpty || !contentId.isEmpty else { return nil }

        let titleId = SFO.string(sfo, "TITLE_ID")
        let category = SFO.string(sfo, "CATEGORY")
        // Update packages: VERSION is the base the patch applies to, APP_VER
        // is the patch itself — prefer APP_VER when present.
        var version = SFO.string(sfo, "APP_VER")
        if version.isEmpty { version = SFO.string(sfo, "VERSION") }

        var params: [PkgParam] = []
        for key in sfo.keys.sorted() {
            let text = sfo[key]?.text ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                params.append(PkgParam(key, text))
            }
        }

        return PkgInfo(
            title: title,
            contentId: contentId,
            titleId: titleId,
            contentType: category,
            version: version,
            isDLC: category.caseInsensitiveCompare("ac") == .orderedSame,
            platform: "PS4",
            description: "[PS4] \(title)",
            packageSize: source.byteCount,
            format: "pkg",
            digest: cnt.digest,
            iconData: cnt.findIcon(),
            params: params
        )
    }

    // MARK: PS5 — param.json inside an FIH-wrapped CNT

    static func readPS5(_ source: any ByteSource, name: String = "") -> PkgInfo? {
        guard let cnt = CntImage.open(source), !cnt.isPKG, !cnt.contentId.isEmpty else {
            return nil
        }
        let contentId = cnt.contentId

        var title = ""
        var version = ""
        var jsonTitleId = ""
        if let pj = cnt.find(id: CntImage.paramJsonId, name: "param.json") {
            let data = cnt.readEntry(pj, cap: ParamJSON.maxBytes)
            if let meta = ParamJSON.parse(data) {
                title = meta.title
                version = meta.version
                jsonTitleId = meta.titleId
            }
        }

        var titleId = jsonTitleId
        if titleId.isEmpty { titleId = titleIdFromContentId(contentId) }
        if title.isEmpty {
            title = titleId.isEmpty ? contentId : titleId
        }

        var params: [PkgParam] = [PkgParam("CONTENT_ID", contentId)]
        if !titleId.isEmpty { params.append(PkgParam("TITLE_ID", titleId)) }
        if !version.isEmpty { params.append(PkgParam("VERSION", version)) }
        params.append(PkgParam("PLATFORM", "PS5"))

        let tag = cnt.isLIH ? "patch" : (cnt.isMeta ? "Meta" : cnt.isDebug ? "Debug" : "Retail")
        return PkgInfo(
            title: title,
            contentId: contentId,
            titleId: titleId,
            version: version,
            isDLC: isDLCHeuristic(title: title, contentId: contentId),
            platform: "PS5",
            description: "[PS5 \(tag)] \(title)",
            packageSize: source.byteCount,
            format: "pkg",
            digest: cnt.digest,
            iconData: cnt.findIcon(),
            params: params
        )
    }

    /// `EP0002-PPSA01325_00-GAME0000000000` -> `PPSA01325`.
    /// The middle field of a content id is the title id, optionally followed
    /// by `_00` (a concept suffix) which is not part of it.
    ///
    /// The candidate is validated as a title id rather than accepted on
    /// length alone: a garbage middle field would otherwise become the row's
    /// family key and silently merge unrelated packages.
    public static func titleIdFromContentId(_ contentId: String) -> String {
        let parts = contentId.split(separator: "-", omittingEmptySubsequences: false)
        var mid = parts.count >= 2 ? String(parts[1]) : contentId
        if let us = mid.firstIndex(of: "_") { mid = String(mid[..<us]) }
        let trimmed = mid.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4, trimmed.count <= 16 else { return "" }
        return GameReader.titleIdFromName(trimmed)
    }

    /// PS5 packages carry no DLC category flag, so the title / content id is
    /// matched against the wording publishers actually use.
    public static func isDLCHeuristic(title: String, contentId: String) -> Bool {
        let t = title.lowercased()
        let c = contentId.lowercased()
        return t.contains("dlc") || t.contains("add-on") || t.contains("addon")
            || t.contains("expansion") || t.contains("season pass")
            || c.contains("-dlc") || c.contains("_dlc") || c.contains("addon")
    }
}
