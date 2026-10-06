import AppKit
import PkgSenderCore
import SwiftUI
import UserNotifications

// MARK: - Event bus
//
// The file server, the discovery sweep and the library scanner all call back
// from non-main threads through `@Sendable` closures. Those closures must not
// capture the (main-actor) `AppModel`, so they post into this stream instead
// and the model consumes it from a `Task` started on the main actor.

/// Sendable bridge from `@Sendable` callbacks to the main actor.
final class EventBus<Value: Sendable>: @unchecked Sendable {
    let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init(bufferingNewest limit: Int = 16) {
        var escaped: AsyncStream<Value>.Continuation!
        stream = AsyncStream(Value.self, bufferingPolicy: .bufferingNewest(limit)) { escaped = $0 }
        continuation = escaped
    }

    func send(_ value: Value) { continuation.yield(value) }
}

/// Everything the server threads may raise back to the model.
enum ServerEvent: Sendable {
    case progress(String)
    case fileRequested(String)
    case log(String)
    case beacon(String)
}

// MARK: - Library snapshot box
//
// Lock-protected: the catalog provider runs on the file server's accept /
// connection threads while the library is rebuilt on the main actor.

final class LibraryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [GameItem] = []
    private var pathToID: [String: String] = [:]
    private var idToPath: [String: String] = [:]
    private var catalog: [CatalogEntry] = []

    // MARK: Items

    /// Replace the whole library (Scan button).
    func replace(_ newItems: [GameItem]) {
        lock.lock()
        items = newItems
        lock.unlock()
    }

    /// Upsert by path (a folder or drive added later).
    func merge(_ newItems: [GameItem]) {
        lock.lock()
        var byPath: [String: Int] = [:]
        for (index, item) in items.enumerated() { byPath[item.path] = index }
        for item in newItems {
            if let index = byPath[item.path] {
                items[index] = item
            } else {
                items.append(item)
                byPath[item.path] = items.count - 1
            }
        }
        lock.unlock()
    }

    func snapshot() -> [GameItem] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    // MARK: Stable url ids

    /// Id of a file, stable across restarts: hash of path + size.
    /// Same file -> same URL forever (the console can resume, its icon cache
    /// stays valid); a changed file (new size) -> new URL.
    func identifier(path: String, size: Int64) -> String {
        lock.lock()
        defer { lock.unlock() }
        let want = Self.stableID(path: path, size: size)
        if pathToID[path] != want {
            pathToID[path] = want
            idToPath[want] = path
        }
        return want
    }

    func knownIdentifier(path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pathToID[path]
    }

    func path(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return idToPath[id]
    }

    static func stableID(path: String, size: Int64) -> String {
        "lib-" + StableID.hex(StableID.fnv1a64(path.lowercased() + "|" + String(size)))
    }

    // MARK: Catalog snapshot

    func setCatalog(_ entries: [CatalogEntry]) {
        lock.lock()
        catalog = entries
        lock.unlock()
    }

    func currentCatalog() -> [CatalogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return catalog
    }

    // MARK: Covers

    /// Cover for a row: its own icon, else the base game's icon from the
    /// same family (patches/DLCs frequently bundle no icon at all).
    func effectiveIcon(for item: GameItem) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let own = item.iconData, !own.isEmpty { return own }
        guard !item.familyKey.isEmpty else { return nil }
        var fallback: Data?
        for candidate in items where candidate.familyKey == item.familyKey
            && candidate.path != item.path {
            guard let icon = candidate.iconData, !icon.isEmpty else { continue }
            if candidate.role == .game { return icon }
            fallback = fallback ?? icon
        }
        return fallback
    }
}

// MARK: - Formatting

enum Format {
    static func bytes(_ value: Int64) -> String { SizeFormatter.string(value) }

    static func speed(_ bps: Double) -> String {
        guard bps.isFinite, bps >= 0 else { return "" }
        if bps >= 1024 * 1024 * 1024 { return String(format: "%.1f GB/s", bps / 1024 / 1024 / 1024) }
        if bps >= 1024 * 1024 { return String(format: "%.1f MB/s", bps / 1024 / 1024) }
        if bps >= 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "calculating…" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "≈ %dh %dm left", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return String(format: "≈ %dm %02ds left", total / 60, total % 60) }
        return String(format: "≈ %ds left", total)
    }

    /// Shortened error text so a raw socket/HTTP dump cannot blow up a row.
    static func short(_ text: String, limit: Int = 120) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

// MARK: - Notifications

/// Local notifications for finished transfers.
///
/// `UNUserNotificationCenter` needs a real bundle; a SwiftPM command-line
/// build has none, so every call is guarded on `bundleIdentifier` and simply
/// becomes a no-op there instead of raising.
enum Notifier {
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// MARK: - Window access

/// Publishes the window that hosts this view so Compact mode can resize it
/// (the upstream Avalonia build does the same with `TopLevel.GetTopLevel`).
struct WindowAccessor: NSViewRepresentable {
    final class Coordinator: NSObject {
        var onResolve: ((NSWindow?) -> Void)?
        init(onResolve: ((NSWindow?) -> Void)? = nil) { self.onResolve = onResolve }
    }

    let onResolve: (NSWindow?) -> Void

    init(_ onResolve: @escaping (NSWindow?) -> Void) {
        self.onResolve = onResolve
    }

    func makeCoordinator() -> Coordinator { Coordinator(onResolve: onResolve) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.onResolve?(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.onResolve?(nsView.window)
        }
    }
}

// MARK: - Bundle resources

/// Assets shipped in `Resources/` (SPM resource bundle).
enum AppAssets {
    static let receiverFileName = "pkg-receiver.elf"

    static func logo() -> NSImage? {
        Bundle.module.image(forResource: "logo")
    }

    static func aboutImage() -> NSImage? {
        Bundle.module.image(forResource: "assets_about")
    }

    /// Absolute path of the receiver ELF, for the Guide / About dialogs.
    static func receiverPath() -> String? {
        if let url = Bundle.module.url(forResource: "pkg-receiver", withExtension: "elf") {
            return url.path
        }
        // Fallback: SPM puts processed resources next to the executable when
        // no bundle is produced (e.g. `swift build` output).
        let executable = CommandLine.arguments.first ?? ""
        let directory = (executable as NSString).deletingLastPathComponent
        let candidate = (directory as NSString).appendingPathComponent(receiverFileName)
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    /// PS4 DPI payload bytes; the installer is useless without them.
    static func ps4Payload() -> Data {
        if let url = Bundle.module.url(forResource: "ps4_dpi_payload", withExtension: "bin"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let executable = CommandLine.arguments.first ?? ""
        let directory = (executable as NSString).deletingLastPathComponent
        let candidate = (directory as NSString).appendingPathComponent("ps4_dpi_payload.bin")
        return (try? Data(contentsOf: URL(fileURLWithPath: candidate))) ?? Data()
    }

    /// Reveal a shipped resource in Finder (Guide / About "Show resources").
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - Shell helpers

enum Shell {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        open(url)
    }

    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

// MARK: - Open panel

/// `NSOpenPanel` wrapper — the macOS stand-in for Avalonia's storage
/// provider and for the upstream drive picker.
enum OpenPanel {
    /// Pick one or more folders.
    @MainActor
    static func chooseFolders(title: String, directory: String? = nil, multiple: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        panel.resolvesAliases = true
        panel.prompt = L10n.shared.t("panel.addPrompt")
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// "Scan drives…" — the macOS equivalent of picking whole volumes:
    /// the panel opens on `/Volumes` so every mounted disk is one click away.
    @MainActor
    static func chooseVolumes(title: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = L10n.shared.t("panel.scanPrompt")
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        return panel.runModal() == .OK ? panel.urls : []
    }
}
