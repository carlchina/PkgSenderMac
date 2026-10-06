import Foundation

/// Reads and writes `AppSettings` as JSON under
/// `~/Library/Application Support/PkgSender/settings.json`.
///
/// The store is a value type with no mutable state, so it can be used from
/// any thread without locking. Writes are atomic: the JSON lands in a
/// temporary file in the same directory and is then moved over the target.
/// A crash (or a full disk) mid-write therefore leaves the previous
/// settings intact rather than a truncated file that would silently reset
/// every field on the next launch.
public struct SettingsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Store inside an application-support directory (tests pass a temp dir).
    public init(applicationSupportDirectory: URL) {
        self.init(fileURL: applicationSupportDirectory
            .appendingPathComponent("PkgSender")
            .appendingPathComponent("settings.json"))
    }

    /// `~/Library/Application Support/PkgSender/settings.json`.
    public static var standard: SettingsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
        // `URL.homeDirectory` is macOS 13+; the FileManager call is not, and
        // the package targets macOS 12.
        let root = base ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
        return SettingsStore(applicationSupportDirectory: root)
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Load, or the defaults when the file is missing, unreadable or
    /// hand-corrupted. A broken settings file must never block launch.
    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        guard let decoded = try? decoder.decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return decoded.normalized
    }

    /// Write atomically. Throws only when the directory cannot be created or
    /// the file cannot be replaced — callers may treat that as non-fatal.
    public func save(_ settings: AppSettings) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings.normalized)

        // Same directory, so the final step is a rename rather than a copy
        // across volumes (which is not atomic).
        let temp = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temp)
        } catch {
            // No existing file to replace on a first run: move instead.
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: temp, to: fileURL)
        }
        // Settings hold a console address; keep them readable only by the user.
        chmod(fileURL.path, 0o600)
    }

    /// Remove the file; used by "reset settings" and by tests.
    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private var decoder: JSONDecoder { JSONDecoder() }
}
