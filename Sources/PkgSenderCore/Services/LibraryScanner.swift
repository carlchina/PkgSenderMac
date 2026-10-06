import Foundation

/// Recursive scan for every container PKG Sender can send.
///
/// Files are collected by extension at any depth (`.pkg`, `.exfat`,
/// `.ffpfsc`, `.ffpkg`) plus dumped app folders (`sce_sys/param.json`), which
/// are collected but not descended into. The walk is iterative and isolates
/// per-directory errors, so a denied folder or a broken external drive skips
/// just that directory instead of aborting the scan.
///
/// Unlike the upstream C# scanner this returns **images too**. Upstream
/// filtered a dropped file down to `.pkg` only, so dragging an `.exfat` /
/// `.ffpkg` / `.ffpfsc` image onto the window did nothing at all — the file
/// was never enqueued and never reported. `read(urls:)` is the drop handler's
/// entry point and accepts all four container extensions.
public struct LibraryScanner: Sendable {
    /// Progress text. `@Sendable` because scanning runs off the main thread;
    /// the UI hop back to the main actor happens inside the closure.
    public typealias ProgressHandler = @Sendable (String) -> Void

    /// Guard against pathological trees (a drive root with a loop of
    /// bind mounts, or a restore directory with hundreds of thousands of
    /// folders). Symlinks are skipped, but the budget caps the worst case.
    public let maxDirectories: Int

    public init(maxDirectories: Int = 200_000) {
        self.maxDirectories = max(1, maxDirectories)
    }

    // MARK: - Scanning

    /// Scan `roots` and return one row per sendable item, sorted by title.
    public func scan(roots: [URL], progress: ProgressHandler? = nil) -> [GameItem] {
        let (files, folders) = collect(roots: roots, progress: progress)
        let total = files.count + folders.count
        var items: [GameItem] = []
        items.reserveCapacity(total)
        var done = 0
        for url in files + folders {
            done += 1
            progress?("Reading \(done)/\(total): \(url.lastPathComponent)")
            if let info = GameReader.read(url: url) {
                items.append(GameItem(path: url.path, info: info))
            }
        }
        return Self.finish(items)
    }

    /// Same work off the calling thread — the walk touches thousands of
    /// directories and would otherwise stall the UI.
    public func scanAsync(roots: [URL],
                          progress: ProgressHandler? = nil) async -> [GameItem] {
        let scanner = self
        return await Task.detached(priority: .userInitiated) {
            scanner.scan(roots: roots, progress: progress)
        }.value
    }

    /// Read explicitly-provided files or folders (drag & drop, "open…").
    ///
    /// Every game container is accepted — not just `.pkg` — and a dropped
    /// folder becomes a scan root's worth of items. Anything unreadable is
    /// skipped rather than failing the whole drop.
    public func read(urls: [URL], progress: ProgressHandler? = nil) -> [GameItem] {
        var items: [GameItem] = []
        var done = 0
        for url in urls {
            done += 1
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path,
                                                 isDirectory: &isDirectory) else { continue }
            progress?("Reading \(done)/\(urls.count): \(url.lastPathComponent)")
            if isDirectory.boolValue {
                if let info = GameReader.read(url: url) {
                    items.append(GameItem(path: url.path, info: info))
                } else {
                    items += scan(roots: [url], progress: nil)
                }
                continue
            }
            guard GameReader.isGameFile(url) else { continue }
            if let info = GameReader.read(url: url) {
                items.append(GameItem(path: url.path, info: info))
            }
        }
        return Self.finish(items)
    }

    // MARK: - Post-processing (pure, unit-testable)

    /// Dedupe + family linking + final sort.
    public static func finish(_ items: [GameItem]) -> [GameItem] {
        let unique = deduplicate(items)
        let linked = linkFamilies(unique)
        return linked.sorted {
            let byTitle = $0.title.localizedCaseInsensitiveCompare($1.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return $0.path < $1.path
        }
    }

    /// Drop rows that point at the same file, or at two byte-identical
    /// copies of one package.
    ///
    /// Path dedupe comes first (case- and `..`-insensitive). Content dedupe
    /// then keys on the content id when there is one — it is unique per
    /// package, so an update and its base game are never merged — and on
    /// title id + size for images, which have no content id.
    public static func deduplicate(_ items: [GameItem]) -> [GameItem] {
        var seenPaths: Set<String> = []
        var seenContent: Set<String> = []
        var out: [GameItem] = []
        out.reserveCapacity(items.count)
        for item in items.sorted(by: { $0.path < $1.path }) {
            let key = (item.path as NSString).standardizingPath.lowercased()
            guard seenPaths.insert(key).inserted else { continue }
            if let content = contentKey(item), !seenContent.insert(content).inserted {
                continue
            }
            out.append(item)
        }
        return out
    }

    /// Second pass: attach updates/DLCs to their base game so the UI can
    /// show a family badge. A key derived from a file name (`FILE:…`) never
    /// links — that would merge unrelated rows that merely share a name.
    public static func linkFamilies(_ items: [GameItem]) -> [GameItem] {
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() {
            groups[item.familyKey, default: []].append(index)
        }
        var out = items
        for (key, indices) in groups {
            let ordered = indices.sorted { a, b in
                if out[a].role.rank != out[b].role.rank {
                    return out[a].role.rank < out[b].role.rank
                }
                if out[a].sizeBytes != out[b].sizeBytes {
                    return out[a].sizeBytes > out[b].sizeBytes
                }
                return out[a].title.localizedCaseInsensitiveCompare(out[b].title)
                    == .orderedAscending
            }
            let linked = !key.hasPrefix("FILE:") && ordered.count > 1
            let tip = linked
                ? "Linked:\n" + ordered.map {
                    "• \(out[$0].title) (\(out[$0].role.rawValue), \(out[$0].sizeText))"
                }.joined(separator: "\n")
                : ""
            for index in ordered {
                out[index].familyCount = linked ? ordered.count : 0
                out[index].hasFamily = linked
                out[index].familyTip = tip
            }
        }
        return out
    }

    private static func contentKey(_ item: GameItem) -> String? {
        if !item.contentId.isEmpty {
            return "cid:\(item.contentId):\(item.sizeBytes)"
        }
        // Images carry at most a title id; same id + same size means the same
        // dump copied twice.
        if item.format != "pkg", !item.titleId.isEmpty {
            return "tid:\(item.titleId):\(item.sizeBytes)"
        }
        return nil
    }

    // MARK: - Walk

    /// Iterative full-tree walk. Per-directory errors are swallowed, system
    /// and recycle directories are skipped, and symlinks are never followed
    /// (no loops, no escaping the root).
    private func collect(roots: [URL],
                         progress: ProgressHandler?) -> (files: [URL], folders: [URL]) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var files: [URL] = []
        var folders: [URL] = []
        var stack: [URL] = []
        var budget = maxDirectories

        for root in roots {
            guard Self.isExistingDirectory(root) else { continue }
            progress?("Walking \(root.lastPathComponent)…")
            stack.append(root)
        }

        var visited = 0
        while let directory = stack.popLast() {
            guard budget > 0 else { break }
            budget -= 1
            visited += 1
            if visited % 500 == 0 { progress?("Walking… \(visited) folders") }

            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: Array(keys), options: [])
            } catch {
                continue        // denied, unmounted, gone — skip this one only
            }

            for entry in entries {
                let values = try? entry.resourceValues(forKeys: keys)
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true {
                    let name = entry.lastPathComponent
                    if name.hasPrefix("$") { continue }
                    if name.caseInsensitiveCompare("System Volume Information") == .orderedSame {
                        continue
                    }
                    if GameReader.isGameFolder(entry) {
                        folders.append(entry)   // game folder: collect, don't descend
                    } else {
                        stack.append(entry)
                    }
                } else if GameReader.isGameFile(entry) {
                    files.append(entry)
                }
            }
        }
        return (files, folders)
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
