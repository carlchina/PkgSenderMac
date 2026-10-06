import Foundation

/// Format dispatch for every container PKG Sender accepts.
///
/// Parsing is *best effort* by design: sending never depends on it, because
/// raw bytes (or a folder) go over the wire as-is. A file that cannot be
/// understood still has to appear in the library, so `.ffpfsc` / `.ffpkg` and
/// unreadable `.exfat` images fall back to a filename stub instead of being
/// dropped.
public enum GameReader {
    /// Containers that hold sendable content.
    public static let gameExtensions: Set<String> = ["pkg", "exfat", "ffpfsc", "ffpkg"]

    public static func isGameFile(_ url: URL) -> Bool {
        gameExtensions.contains(url.pathExtension.lowercased())
    }

    /// A dumped PS5 app folder: `sce_sys/param.json`.
    public static func isGameFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: url.appendingPathComponent("sce_sys")
                .appendingPathComponent("param.json").path)
    }

    public static func read(url: URL) -> PkgInfo? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return readFolder(url) }
        switch url.pathExtension.lowercased() {
        case "pkg":
            return PkgReader.read(url: url)
        case "exfat":
            // Real exFAT walk first; a stub keeps the row sendable when the
            // image uses a layout this walker does not understand.
            return ExfatReader.read(url: url) ?? imageStub(url)
        case "ffpfsc", "ffpkg":
            // Full PFS/UFS parsing needs stacks we do not ship; the file name
            // carries the title id, which is enough to identify the row.
            return imageStub(url)
        default:
            return nil
        }
    }

    // MARK: - App folders

    /// PS5 app dump: `sce_sys/param.json` + `icon0.png`, size summed over the
    /// whole tree (folders shift around, so the total is computed on demand).
    static func readFolder(_ url: URL) -> PkgInfo? {
        let sce = url.appendingPathComponent("sce_sys")
        let paramURL = sce.appendingPathComponent("param.json")
        guard let data = try? Data(contentsOf: paramURL),
              let meta = ParamJSON.parse(data) else { return nil }

        var icon: Data?
        let iconURL = sce.appendingPathComponent("icon0.png")
        if let raw = try? Data(contentsOf: iconURL), raw.count >= 8,
           raw[0] == 0x89, raw[1] == 0x50, raw.count <= 8 * 1024 * 1024 {
            icon = raw
        }

        let (total, files) = folderStats(url)
        let title = meta.title.isEmpty ? url.lastPathComponent : meta.title

        var params: [PkgParam] = []
        if !meta.titleId.isEmpty { params.append(PkgParam("TITLE_ID", meta.titleId)) }
        if !meta.contentId.isEmpty { params.append(PkgParam("CONTENT_ID", meta.contentId)) }
        if !meta.version.isEmpty { params.append(PkgParam("VERSION", meta.version)) }
        params.append(PkgParam("FILES", "\(files)"))

        return PkgInfo(title: title,
                       contentId: meta.contentId,
                       titleId: meta.titleId,
                       version: meta.version,
                       platform: "PS5",
                       description: "[PS5 folder] \(title)",
                       packageSize: total,
                       format: "folder",
                       isFolder: true,
                       iconData: icon,
                       params: params)
    }

    /// Tolerant walk: a denied subdirectory is skipped, not fatal.
    static func folderStats(_ root: URL) -> (Int64, Int) {
        var total: Int64 = 0
        var count = 0
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return (0, 0) }
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                count += 1
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return (total, count)
    }

    // MARK: - Image stub

    /// Metadata stub for images whose container cannot be walked here.
    /// Title id comes from the file name, size from disk, no cover.
    static func imageStub(_ url: URL) -> PkgInfo {
        let ext = url.pathExtension.lowercased()
        let format = gameExtensions.contains(ext) ? ext : "ffpkg"
        let titleId = titleIdFromName(url.lastPathComponent)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)??.int64Value ?? 0
        let title = titleId.isEmpty ? url.lastPathComponent : titleId
        var params: [PkgParam] = []
        if !titleId.isEmpty { params.append(PkgParam("TITLE_ID", titleId)) }
        return PkgInfo(title: title,
                       titleId: titleId,
                       platform: "PS5",
                       description: "[PS5 \(format) image] \(title)",
                       packageSize: size,
                       format: format,
                       params: params)
    }

    /// `PPSA01325` / `CUSA00001` / `NPXX12345` style ids, as dumpers
    /// (and the upstream tool) put them in file names.
    ///
    /// Implemented as a plain scan rather than a regex so it stays a pure
    /// function with no shared mutable state — it runs once per scanned file.
    public static func titleIdFromName(_ name: String) -> String {
        let chars = Array(name.uppercased())
        let prefixes: Set<String> = ["PPSA", "PPCS", "CUSA"]
        var i = 0
        while i + 9 <= chars.count {
            let letters = String(chars[i..<(i + 4)])
            let digits = chars[(i + 4)..<(i + 9)]
            let isKnown = prefixes.contains(letters)
                || (["NP", "BL", "BC"].contains(String(letters.prefix(2)))
                    && letters.allSatisfy { $0.isLetter })
            if isKnown, digits.allSatisfy({ $0.isNumber }),
               (i == 0 || !chars[i - 1].isLetter),
               (i + 9 == chars.count || !(chars[i + 9].isNumber || chars[i + 9].isLetter)) {
                return String(chars[i..<(i + 9)])
            }
            i += 1
        }
        return ""
    }
}
