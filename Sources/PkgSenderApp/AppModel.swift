import AppKit
import PkgSenderCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Small value types

/// Colour of the live receiver dot: green connected, red no receiver,
/// grey no network (upstream `LiveProbeAsync`).
enum DotKind { case none, ok, bad, warn }

/// What the library panel shows: empty/loading/loaded/error.
enum LibraryPhase: Equatable {
    case empty(String)
    case loading
    case loaded
    case error(String)

    var message: String {
        switch self {
        case .empty(let text), .error(let text): return text
        case .loading: return "Scanning…"
        case .loaded: return ""
        }
    }
}

struct SwitchPrompt: Sendable, Hashable {
    let from: String
    let address: String
    let source: String
}

/// Resume / overwrite / cancel for a file that already exists on the console.
struct CopyPrompt: Sendable, Identifiable {
    let id = UUID()
    let fileName: String
    let remoteText: String
    let localText: String
    let canResume: Bool
    let complete: Bool
}

enum CopyChoice: Sendable { case cancel, overwrite, resume }

enum SheetItem: Identifiable {
    case about
    case guide
    case switchConsole(SwitchPrompt)
    case copyChoice(CopyPrompt)

    var id: String {
        switch self {
        case .about: return "about"
        case .guide: return "guide"
        case .switchConsole(let prompt): return "switch-\(prompt.address)"
        case .copyChoice(let prompt): return "copy-\(prompt.id.uuidString)"
        }
    }
}

/// Result of one background filter pass (pure, Sendable).
private struct FilterResult: Sendable {
    var rows: [GameItem]
    var ps5: Int
    var ps4: Int
    var families: Int
}

// MARK: - AppModel

/// Everything the window shows and does.
///
/// `@MainActor` so every published field and every queue dictionary is touched
/// from one thread only. The file server, the sweeper and the scanner all call
/// back through `EventBus` / `LibraryBox`, never by capturing this object —
/// `@Sendable` closures that captured it would not compile under Swift 6.
@MainActor
final class AppModel: ObservableObject {

    // MARK: Connection

    @Published var psIP: String = ""
    @Published var pcIP: String = ""
    @Published var remoteDir: String = "/data/homebrew"
    @Published var launchAtLogin: Bool = false

    // MARK: Network

    @Published var networks: [LanNetwork] = []
    @Published var pcOptions: [LanNetwork] = []

    // MARK: Status line

    @Published var status: String = ""
    @Published var dotText: String = "○ No network"
    @Published var dot: DotKind = .none
    @Published var isBusy: Bool = false
    @Published var isSending: Bool = false
    @Published var speedText: String = ""
    @Published var etaText: String = ""

    // MARK: Library

    @Published var search: String = ""
    @Published var platformFilter: String = "All"
    @Published var sortMode: String = "Name"
    @Published var hideExtras: Bool = false
    @Published var games: [GameItem] = []
    @Published var phase: LibraryPhase = .empty("Add a folder or drives first.")
    @Published var isFiltering: Bool = false
    @Published var filterLabel: String = ""
    @Published var gamesLabel: String = ""
    @Published var selection: Set<String> = []
    @Published var hasPkgSelection: Bool = false
    @Published var hasImageSelection: Bool = false

    // MARK: Queue

    @Published var queue: [QueueEntry] = []
    @Published var queueLabel: String = "Queue is empty"
    @Published var pauseAllLabel: String = "⏸ Pause all"
    @Published var totalProgress: Double = 0
    /// "PS4 console": installs strictly one-by-one.
    @Published var sequentialMode: Bool = false

    // MARK: Layout / share

    @Published var compact: Bool = false
    @Published var shared: Bool = false
    @Published var shareLabel: String = "Share to console"

    // MARK: Dialogs

    @Published var sheet: SheetItem? = nil

    // MARK: Update

    /// A newer release exists on the watched repo.
    @Published var updateAvailable: Bool = false
    /// A check is in flight (drives the spinner in About).
    @Published var updateChecking: Bool = false
    /// Latest tag, e.g. "v1.3.0" (shown when an update is available).
    @Published var updateLatestVersion: String = ""
    /// Where to download the new build.
    @Published var updateReleaseURL: URL? = nil
    /// Whether the launch-time / automatic check runs.
    @Published var updateCheck: Bool = true

    // MARK: Persistent / private state

    private let l10n = L10n.shared
    private let store = SettingsStore.standard
    private let library = LibraryBox()
    private let events = EventBus<ServerEvent>(bufferingNewest: 64)
    private let client = ConsoleClient()
    private let discovery = NetworkDiscovery()
    private let ps4: PS4Installer
    private var aboutShown: Bool = false
    /// Key of the current `phase` message so `relocalize()` can rebuild it.
    private var phaseMessageKey: String?

    private var server: RangeHTTPServer?
    private var roots: [String] = []
    private var all: [GameItem] = []

    // Queue bookkeeping, keyed by `QueueEntry.id` (== `GameItem.id`).
    private var runQueue: [String] = []
    private var activeIDs: [String: String] = [:]
    private var activeIdle: [String: Int] = [:]
    private var activeSince: [String: Date] = [:]
    private var stallSince: [String: (Date, Int64)] = [:]
    private var speedSamples: [String: [(Date, Int64)]] = [:]
    private var passiveLast: [String: Int64] = [:]
    private var running = false
    private var copyStop = false
    private var lastServe = Date.distantPast

    private var anchor: Int? = nil
    private var counts = FilterResult(rows: [], ps5: 0, ps4: 0, families: 0)

    private var detecting = false
    private var probing = false
    private var eventTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var filterTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?

    private var switchContinuation: CheckedContinuation<Bool, Never>?
    private var copyContinuation: CheckedContinuation<CopyChoice, Never>?

    /// Sequential (PS4) gate: the next push waits for the previous download
    /// unless it has been silent for this long — a pause on the console then
    /// holds the gate briefly, never forever.
    private static let gateSkipAfter: TimeInterval = 60
    /// Completion tolerance: the server counts bytes after a successful socket
    /// write, so a client disconnect on the last chunk leaves the counter up
    /// to one buffer short of a fully downloaded file.
    private static let completionTolerance: Int64 = 1024 * 1024
    /// Stable samples before a row is accepted as done.
    private static let doneSamples = 5

    static let platformOptions = ["All", "PS5", "PS4"]
    static let sortOptions = ["Name", "Size ↓", "Size ↑"]

    // MARK: - Init

    init() {
        ps4 = PS4Installer(payload: AppAssets.ps4Payload())
        let settings = store.load()
        psIP = settings.psIP
        pcIP = settings.pcIP
        remoteDir = settings.remoteDir
        aboutShown = settings.aboutShown
        updateCheck = settings.updateCheck
        roots = settings.libraryRoots
        phaseMessageKey = "library.emptyAddFirst"
        phase = .empty(l10n.t("library.emptyAddFirst"))
        dotText = l10n.t("conn.dotNoNetwork")
        queueLabel = l10n.t("queue.empty")
        pauseAllLabel = l10n.t("queue.pauseAll")
        shareLabel = l10n.t("status.shareToConsole")
    }

    // MARK: - Startup

    func start() {
        Notifier.requestAuthorization()
        launchAtLogin = LoginItemManager.isEnabled

        startEventPump()
        refreshNetworks()
        if networks.isEmpty {
            status = l10n.t("conn.noNetwork")
        }
        startLiveProbe()

        if roots.isEmpty {
            setEmptyPhase("library.emptyAddFirst")
        } else {
            setEmptyPhase("library.emptyPressScan")
        }

        if aboutShown {
            Task { await autoDetect() }
        } else {
            // First launch: About (support links) first, detection after it.
            sheet = .about
        }

        startUpdateCheckIfEnabled()
    }

    /// Set the library's empty/error message from a localisation key and
    /// remember the key so `relocalize()` can rebuild it after a language swap.
    @discardableResult
    private func setEmptyPhase(_ key: String) -> LibraryPhase {
        phaseMessageKey = key
        let p = LibraryPhase.empty(l10n.t(key))
        phase = p
        return p
    }

    @discardableResult
    private func setErrorPhase(_ key: String) -> LibraryPhase {
        phaseMessageKey = key
        let p = LibraryPhase.error(l10n.t(key))
        phase = p
        return p
    }

    /// Rebuild every text the model owns after the UI language changes.
    func relocalize() {
        if let key = phaseMessageKey {
            if case .error = phase { phase = .error(l10n.t(key)) }
            else { phase = .empty(l10n.t(key)) }
        }
        updateGamesLabel()
        updateQueueLabel()
        updateShareLabel()
        Task { await liveProbe() }
        scheduleFilter(debounce: false)
    }

    private func startEventPump() {
        eventTask = Task { [weak self] in
            for await event in self?.events.stream ?? AsyncStream { _ in } {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .progress(let text):
            status = text
        case .beacon(let address):
            status = l10n.t("status.beacon", address)
        case .fileRequested(let id):
            lastServe = Date()
            updateShareLabel()
            log("console requested /pkg/\(id)")
        case .log(let line):
            log(line)
        }
    }

    // MARK: - Settings

    private func persist() {
        let settings = AppSettings(
            psIP: psIP,
            pcIP: pcIP,
            remoteDir: remoteDir,
            chunkSize: AppSettings.defaultChunkSize,
            updateCheck: updateCheck,
            aboutShown: aboutShown,
            libraryRoots: roots
        )
        try? store.save(settings)
    }

    func noteConsoleAddressChange() { persist() }

    // MARK: - Networks

    func refreshNetworks() {
        networks = LanNetwork.localNetworks(includeVirtual: false)
        pcOptions = LanNetwork.localNetworks(includeVirtual: true)
        if let best = LanNetwork.bestLocalAddress(pcOptions, consoleAddress: psIP) {
            pcIP = best.description
        } else if let first = pcOptions.first {
            pcIP = first.address.description
        }
    }

    /// PC address label for the popup: `192.168.1.5  (en0 /24)`.
    func label(for network: LanNetwork) -> String {
        "\(network.address)  (\(network.interfaceName) /\(network.prefixLength))"
    }

    func selectPC(_ network: LanNetwork) {
        pcIP = network.address.description
        persist()
    }

    // MARK: - Detection / probe

    private func startLiveProbe() {
        probeTask = Task { [weak self] in
            while true {
                guard let self else { return }
                await self.liveProbe()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func liveProbe() async {
        updateShareLabel()
        guard !networks.isEmpty else {
            dotText = l10n.t("conn.dotNoNetwork")
            dot = .none
            return
        }
        let address = psIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !detecting, !probing else { return }
        probing = true
        defer { probing = false }

        let (online, busy) = await discovery.probe(host: address)
        if !online {
            // No PS5 receiver — a PS4 (RPI / GoldHEN) installs fine too, so
            // detect it instead of showing a red dot while pushes work.
            let method = await ps4.detect(host: address)
            if method == .offline {
                dotText = l10n.t("conn.dotNoReceiver")
                dot = .bad
            } else {
                dotText = l10n.t("conn.dotConnectedPS4", method.rawValue)
                dot = .ok
            }
            return
        }
        dotText = busy == true ? l10n.t("conn.dotConnectedBusy") : l10n.t("conn.dotConnected")
        dot = .ok
    }

    func testConnection() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        status = l10n.t("status.testing", psIP)
        dotText = l10n.t("conn.dotTesting")
        dot = .warn
        let method = await ps4.detect(host: psIP, fresh: true)
        var online = method != .offline
        if !online { online = await client.isOnline(host: psIP) }
        let what = method != .offline ? "PS4 \(method.rawValue)" : "pkg-receiver"
        status = online
            ? l10n.t("status.connected", what, psIP)
            : l10n.t("status.noConnection", psIP)
        dotText = online ? l10n.t("conn.dotConnected") : l10n.t("conn.dotNoConnection")
        dot = online ? .ok : .bad
    }

    /// Startup auto-detect: saved address first, then beacon + sweep. A
    /// console answering on a *different* address is offered as a switch.
    func autoDetect() async {
        guard !detecting else { return }
        detecting = true
        defer {
            detecting = false
            Task { await self.liveProbe() }
        }
        refreshNetworks()
        guard !networks.isEmpty else {
            status = l10n.t("conn.noNetwork")
            return
        }
        let saved = psIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty {
            let (reachable, _) = await discovery.probe(host: saved)
            if reachable {
                status = l10n.t("status.consoleAt", saved)
                return
            }
        }
        status = l10n.t("status.lookingForConsole")
        let bus = events
        let found = await discovery.findConsoles(
            networks: networks,
            beaconTimeout: 4,
            progress: { text in bus.send(.progress(text)) },
            onBeacon: { address in bus.send(.beacon(address)) }
        )
        let verified = found.filter { $0.source == .beacon || $0.source == .sweep }
        if verified.contains(where: { $0.address == saved }) {
            status = l10n.t("status.consoleAt", saved)
            return
        }
        guard let pick = verified.first else {
            status = saved.isEmpty
                ? l10n.t("status.noConsoleLan")
                : l10n.t("status.noReceiverAt", saved)
            return
        }
        let prompt = SwitchPrompt(from: saved.isEmpty ? "(none)" : saved,
                                  address: pick.address,
                                  source: pick.source.rawValue)
        guard await askSwitch(prompt) else {
            status = l10n.t("status.kept", saved)
            return
        }
        psIP = pick.address
        if let best = LanNetwork.bestLocalAddress(pcOptions, consoleAddress: pick.address) {
            pcIP = best.description
        }
        persist()
        status = l10n.t("status.switched", pick.address)
    }

    // MARK: - Scanning

    func scanButton() {
        guard !roots.isEmpty else {
            status = l10n.t("status.addFolderFirst")
            return
        }
        Task { await scan(paths: roots, merge: false) }
    }

    func addFolder() {
        let picked = OpenPanel.chooseFolders(title: l10n.t("panel.addFolder"))
        acceptRoots(picked.map(\.path))
    }

    /// "Scan drives…" — the macOS counterpart of the upstream drive picker:
    /// the panel opens on `/Volumes` so every mounted disk is one click away.
    func addDrives() {
        let picked = OpenPanel.chooseVolumes(title: l10n.t("panel.scanDrives"))
        acceptRoots(picked.map(\.path))
    }

    private func acceptRoots(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        var added: [String] = []
        for path in paths where !roots.contains(path) {
            roots.append(path)
            added.append(path)
        }
        if !added.isEmpty { persist() }
        // Scan straight away — picking a folder is an implicit "scan this".
        // Re-picking a folder already in the list is treated as a request to
        // refresh it, so the panel never feels like it did nothing.
        Task { await scan(paths: paths, merge: true) }
    }

    /// A scan asked for while another one is still running. Dropping it
    /// would leave newly added roots unscanned until the user pressed Scan
    /// again, so the request is remembered and replayed when the current
    /// scan finishes.
    private var rescanPending: (paths: [String], merge: Bool)?

    func scan(paths: [String], merge: Bool) async {
        guard !isBusy else {
            rescanPending = (paths, merge)
            return
        }
        isBusy = true
        phase = .loading
        status = l10n.t("status.scanning")
        defer {
            isBusy = false
            if let pending = rescanPending {
                rescanPending = nil
                Task { await scan(paths: pending.paths, merge: pending.merge) }
            }
        }

        let urls = paths.map { URL(fileURLWithPath: $0) }
        let scanner = LibraryScanner()
        let bus = events
        let found = await scanner.scanAsync(roots: urls) { text in bus.send(.progress(text)) }
        let rows = found.filter { !$0.isFolder }
        if merge { library.merge(rows) } else { library.replace(rows) }
        all = library.snapshot()
        if shared { publishCatalog() }
        await computeFilter()
        let count = all.count
        status = all.isEmpty ? l10n.t("status.noPkgFound") : l10n.t("status.gamesInLibrary", count)
        if all.isEmpty {
            setEmptyPhase("library.emptyNoFiles")
        } else {
            phase = .loaded
        }
    }

    // MARK: - Drag & drop

    /// Directories become scan roots; loose containers are read and PKGs go
    /// straight to the install queue (upstream behaviour). Images are added
    /// to the library so they can be copied.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                guard let url else { return }
                Task { @MainActor in self.acceptDropped(url) }
            }
        }
        return accepted
    }

    private func acceptDropped(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
        if isDirectory.boolValue {
            acceptRoots([url.path])
            return
        }
        guard GameReader.isGameFile(url) else {
            status = l10n.t("status.dropPkg")
            return
        }
        status = l10n.t("status.reading", url.lastPathComponent)
        let scanner = LibraryScanner()
        let items = scanner.read(urls: [url])
        guard let item = items.first else {
            status = l10n.t("status.couldNotRead", url.lastPathComponent)
            return
        }
        if item.role == .image {
            library.merge([item])
            all = library.snapshot()
            if shared { publishCatalog() }
            scheduleFilter(debounce: false)
            status = l10n.t("status.addedToLibrary", item.title)
        } else {
            enqueue([item])
        }
    }

    // MARK: - Filtering

    func scheduleFilter(debounce: Bool = true) {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            await self.computeFilter()
        }
    }

    func computeFilter() async {
        let snapshot = all
        let raw = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = raw.lowercased()
        let platform = platformFilter
        let sort = sortMode
        let hide = hideExtras

        let result = await Task.detached(priority: .userInitiated) { () -> FilterResult in
            Self.computeRows(all: snapshot, query: query, platform: platform, sort: sort, hideExtras: hide)
        }.value

        counts = result
        games = result.rows
        isFiltering = !query.isEmpty
        filterLabel = query.isEmpty
            ? ""
            : (result.rows.isEmpty
                ? l10n.t("library.noMatches", raw)
                : l10n.t("library.filterMatches", raw, result.rows.count, snapshot.count))
        updateGamesLabel()
    }

    /// Pure filter + sort, mirroring the upstream `ComputeFiltered`.
    ///
    /// `nonisolated` so it can run on a detached task — huge archives must not
    /// filter on the main actor.
    nonisolated private static func computeRows(all: [GameItem],
                                    query: String,
                                    platform: String,
                                    sort: String,
                                    hideExtras: Bool) -> FilterResult {
        var ps5 = 0
        var ps4 = 0
        var families = Set<String>()
        for item in all {
            if item.platform.hasPrefix("PS5") { ps5 += 1 }
            else if item.platform.hasPrefix("PS4") { ps4 += 1 }
            families.insert(item.familyKey)
        }

        var list: [GameItem] = []
        list.reserveCapacity(all.count)
        for item in all {
            if platform == "PS5" && !item.platform.hasPrefix("PS5") { continue }
            if platform == "PS4" && !item.platform.hasPrefix("PS4") { continue }
            if query.isEmpty || item.searchHaystack.contains(query) { list.append(item) }
        }

        // "Hide DLC/updates": collapse each family to its base game(s).
        // A family view (🔗 chip sets `search` to the family key) bypasses the
        // collapse so updates and DLCs become visible again.
        if hideExtras {
            let isFamilyView = !query.isEmpty
                && all.contains { $0.familyKey.lowercased() == query }
            if !isFamilyView {
                var collapsed: [GameItem] = []
                for (key, group) in Dictionary(grouping: list, by: \.familyKey) {
                    if key.hasPrefix("FILE:") {
                        collapsed.append(contentsOf: group)
                        continue
                    }
                    let bases = group.filter { $0.role == .game }
                    let images = group.filter { $0.role == .image }
                    if bases.isEmpty {
                        collapsed.append(contentsOf: group)   // DLC-only family
                    } else {
                        collapsed.append(contentsOf: bases)
                        collapsed.append(contentsOf: images)
                    }
                }
                list = collapsed
            }
        }

        func memberOrder(_ members: [GameItem]) -> [GameItem] {
            members.sorted { lhs, rhs in
                if lhs.role.rank != rhs.role.rank { return lhs.role.rank < rhs.role.rank }
                if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        func representative(_ members: [GameItem]) -> GameItem {
            let ordered = memberOrder(members)
            return ordered.first { $0.role == .game } ?? ordered[0]
        }

        let groups = Dictionary(grouping: list, by: \.familyKey).values
        let orderedFamilies = groups.sorted { lhs, rhs in
            let left = representative(lhs)
            let right = representative(rhs)
            if sort == "Size ↓", left.sizeBytes != right.sizeBytes {
                return left.sizeBytes > right.sizeBytes
            }
            if sort == "Size ↑", left.sizeBytes != right.sizeBytes {
                return left.sizeBytes < right.sizeBytes
            }
            return left.title.localizedCaseInsensitiveCompare(right.title) == .orderedAscending
        }

        var ordered: [GameItem] = []
        for members in orderedFamilies { ordered.append(contentsOf: memberOrder(members)) }
        return FilterResult(rows: ordered, ps5: ps5, ps4: ps4, families: families.count)
    }

    private func updateGamesLabel() {
        let scope: String
        switch platformFilter {
        case "PS5": scope = l10n.t("library.ps5Games", games.count)
        case "PS4": scope = l10n.t("library.ps4Games", games.count)
        default:
            scope = l10n.t("library.gamesInFamilies", games.count, counts.families, counts.ps5, counts.ps4)
        }
        gamesLabel = selection.isEmpty ? scope : scope + l10n.t("library.selected", selection.count)
    }

    /// 🔗 chip inside a card: filter the library to that family (toggles).
    func toggleFamily(_ key: String) {
        search = (search == key) ? "" : key
        scheduleFilter(debounce: false)
    }

    func clearSearch() {
        search = ""
        scheduleFilter(debounce: false)
    }

    // MARK: - Selection

    func select(id: String, command: Bool, shift: Bool) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        if command {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = index
        } else if shift, let anchor {
            let low = min(anchor, index)
            let high = max(anchor, index)
            selection.formUnion(games[low...high].map(\.id))
        } else {
            selection = [id]
            anchor = index
        }
        refreshActionFlags()
    }

    func clearSelection() {
        selection = []
        anchor = nil
        refreshActionFlags()
    }

    /// Select every currently *visible* card (respects the active search and
    /// filters, so "select all" never queues things the user cannot see).
    func selectAll() {
        selection = Set(games.map(\.id))
        anchor = games.isEmpty ? nil : 0
        refreshActionFlags()
    }

    /// Flip the selection on the visible cards — the quickest way to send
    /// "everything except these few".
    func invertSelection() {
        let visible = Set(games.map(\.id))
        selection = visible.subtracting(selection)
        anchor = nil
        refreshActionFlags()
    }

    private func refreshActionFlags() {
        let picked = games.filter { selection.contains($0.id) }
        hasPkgSelection = picked.contains { $0.role != .image }
        hasImageSelection = picked.contains { $0.role == .image }
        updateGamesLabel()
    }

    // MARK: - File server

    @discardableResult
    private func ensureServer() -> Bool {
        if server != nil { return true }
        let newServer = RangeHTTPServer(files: [:], port: RangeHTTPServer.defaultPort)
        newServer.copyBufferSize = 1024 * 1024      // desktop: 1 MB pump buffer
        let bus = events
        newServer.onFileRequested = { id in bus.send(.fileRequested(id)) }
        newServer.onRequestLog = { line in bus.send(.log(line)) }
        do {
            try newServer.start()
        } catch {
            status = l10n.t("status.fileServerFailed", Format.short(error.localizedDescription))
            return false
        }
        server = newServer
        return true
    }

    /// Register a file with the server and return its stable url id.
    @discardableResult
    private func register(game: GameItem) -> String {
        let id = library.identifier(path: game.path, size: game.sizeBytes)
        if let source = RangeSource(fileAtPath: game.path) {
            server?.register(source, for: id)
        }
        return id
    }

    // MARK: - Sharing

    func toggleShare() {
        if shared { stopSharing() } else { startSharing() }
    }

    private func startSharing() {
        guard ensureServer() else { return }
        publishCatalog()
        server?.catalogProvider = { [library] in library.currentCatalog() }
        let address = pcIP
        Task { await discovery.startAnnouncingPc(address: address,
                                                 catalogPort: RangeHTTPServer.defaultPort) }
        shared = true
        updateShareLabel()
        status = l10n.t("status.shared", server?.catalogURL(host: pcIP) ?? "")
    }

    private func stopSharing() {
        server?.catalogProvider = nil
        Task { await discovery.stopAnnouncingPc() }
        shared = false
        updateShareLabel()
        status = l10n.t("status.unshared")
    }

    /// Snapshot the library into catalog rows. A fresh catalog fetch heals
    /// ids left revoked by an old cancel/pause, which would otherwise 404
    /// both `/pkg/{id}` and `/icon/{id}` forever.
    private func publishCatalog() {
        guard let server else { return }
        var rows: [CatalogEntry] = []
        rows.reserveCapacity(all.count)
        for item in all where !item.isFolder {
            let id = library.identifier(path: item.path, size: item.sizeBytes)
            if let path = library.path(for: id), let source = RangeSource(fileAtPath: path) {
                server.register(source, for: id)
            }
            server.unrevoke(id)
            var hasIcon = false
            if let icon = library.effectiveIcon(for: item) {
                server.registerIcon(icon, for: id)
                hasIcon = true
            }
            rows.append(CatalogEntry(
                id: id,
                title: item.title,
                titleId: item.titleId,
                version: item.version,
                size: item.sizeBytes,
                sizeText: item.sizeText,
                role: item.role.rawValue,
                familyKey: item.familyKey,
                platform: item.isPS4 ? "PS4" : "PS5",
                format: item.format,
                file: item.fileName,
                hasIcon: hasIcon
            ))
        }
        library.setCatalog(rows)
    }

    private func updateShareLabel() {
        guard shared else {
            shareLabel = l10n.t("status.shareToConsole")
            return
        }
        shareLabel = Date().timeIntervalSince(lastServe) < 10
            ? l10n.t("status.serving")
            : l10n.t("status.sharedStop")
    }

    // MARK: - Enqueue / push

    func enqueueSelection() {
        let picked = games.filter { selection.contains($0.id) }
        enqueue(picked)
    }

    func enqueue(_ picked: [GameItem]) {
        let wanted = picked.filter { $0.format == "pkg" && !$0.isFolder }
        guard !wanted.isEmpty else {
            status = l10n.t("status.noPkgSelection")
            return
        }
        guard ensureServer() else { return }

        // Never double-push a file that is already queued or downloading.
        let busy = Set(runQueue.compactMap { row(id: $0)?.game.path }
            + activeIDs.keys.compactMap { row(id: $0)?.game.path })
        let fresh = wanted.filter { !busy.contains($0.path) }
        if fresh.isEmpty {
            status = l10n.t("status.alreadyInQueue")
            return
        }

        // Re-sending a stopped row resumes it (same URL, no duplicate row).
        var resumable: [String: String] = [:]
        for entry in queue where entry.canResume && resumable[entry.game.path] == nil {
            resumable[entry.game.path] = entry.id
        }
        var toAdd: [GameItem] = []
        var resumed = 0
        for game in fresh {
            if let rowID = resumable[game.path] {
                resumed += 1
                resumeRow(rowID)
            } else {
                toAdd.append(game)
            }
        }
        if toAdd.isEmpty {
            status = resumed > 0 ? l10n.t("status.resuming") : l10n.t("status.nothingToAdd")
            return
        }
        persist()

        var appended = 0
        for game in toAdd {
            guard !queue.contains(where: { $0.id == game.id }) else { continue }
            queue.append(QueueEntry(game: game, state: .queued, message: l10n.t("status.waiting")))
            runQueue.append(game.id)
            appended += 1
        }
        guard appended > 0 else {
            status = l10n.t("status.alreadyInQueue")
            return
        }
        updateQueueLabel()
        startWorker()
        if running && queue.count > appended {
            status = l10n.t("status.queuedMore", appended)
        }
    }

    private func startWorker() {
        guard !running else { return }
        running = true
        workerTask = Task { [weak self] in
            guard let self else { return }
            await self.runQueueLoop()
        }
    }

    private func runQueueLoop() async {
        isSending = true
        defer { isSending = false }

        while true {
            // Phase 1: hand every ready row to the sender.
            let toPush = pickPushable()
            if !toPush.isEmpty {
                for rowID in toPush { await pushOne(rowID) }
                continue
            }

            // Phase 2: nothing left to hand out. Only keep monitoring while a
            // transfer is actually live. A merely *queued* row must NOT keep
            // the loop alive here: it has to go back through `pickPushable()`
            // to be sent, so treating it as "live work" would strand every
            // remaining row in "waiting" once the first transfer finished.
            guard hasActiveTransfer() else { break }
            monitorTick()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        running = false
        updateEta(activeCount: 0, totalSize: 0, totalServed: 0)
        status = l10n.t("status.queueFinished")
    }

    /// True while the sender still owes the console some bytes — i.e. rows in
    /// flight. Deliberately narrower than "the queue is non-empty": a row that
    /// is only *queued* still needs `pushOne`, so it must not be mistaken for
    /// in-flight work or the worker would monitor it forever instead of sending.
    private func hasActiveTransfer() -> Bool { !activeIDs.isEmpty }

    private func pickPushable() -> [String] {
        let waiting = runQueue.filter { id in
            guard let entry = row(id: id) else { return false }
            return entry.state == .queued && !entry.isPaused
        }
        guard !waiting.isEmpty else { return [] }
        var toPush = waiting
        if sequentialMode {
            // PS4: one at a time. Hold while a previous download is alive.
            let held = activeIDs.keys.contains { id in
                let last = stallSince[id]?.0 ?? activeSince[id] ?? .distantPast
                return Date().timeIntervalSince(last) < Self.gateSkipAfter
            }
            toPush = held ? [] : Array(waiting.prefix(1))
        }
        runQueue.removeAll { toPush.contains($0) }
        return toPush
    }

    private func pushOne(_ rowID: String) async {
        guard let server, let game = row(id: rowID)?.game else { return }
        let id = register(game: game)
        if !activeIDs.values.contains(id) { server.resetServed(id) }
        server.unrevoke(id)
        let url = server.url(host: pcIP, id: id)

        var iconURL: String?
        if let icon = library.effectiveIcon(for: game) {
            server.registerIcon(icon, for: id)
            iconURL = server.iconURL(host: pcIP, id: id)
        }
        updateRow(rowID) {
            $0.state = .sending
            $0.message = l10n.t("status.pushing")
        }
        updateQueueLabel()
        status = l10n.t("status.installingPkg", game.title)

        if game.isPS4 || game.platform.hasPrefix("PS4") {
            await pushPS4(rowID: rowID, game: game, id: id, url: url, iconURL: iconURL)
            return
        }

        let reply = await client.push(host: psIP, url: url, name: game.title, iconURL: iconURL)
        log("[ps5] ok=\(reply.ok) url=\(url) reply=\(reply.body)")
        guard reply.ok else {
            fail(rowID: rowID,
                 message: reply.reached ? Format.short(reply.body, limit: 60) : reply.body)
            status = l10n.t("status.pushFailed", Format.short(reply.body, limit: 120))
            return
        }
        activeIDs[rowID] = id
        activeIdle[rowID] = 0
        activeSince[rowID] = Date()
        // Re-resolve: the row can be removed or moved while `push` was awaited.
        updateRow(rowID) { $0.message = l10n.t("status.queuedOnConsole") }
        updateQueueLabel()
    }

    /// PS4: RPI first (cheap, raw PKG URL), GoldHEN as fallback with the
    /// JSON manifest URL in the callback struct (DPI `RegisterJSON`).
    private func pushPS4(rowID: String, game: GameItem, id: String, url: String, iconURL: String?) async {
        guard let server else { return }
        updateRow(rowID) { $0.message = l10n.t("status.pushingViaPs4") }
        let info = Self.buildPkgInfo(game)

        var (ok, reply) = await ps4.pushRPI(host: psIP, url: url, name: game.title, iconURL: iconURL)
        var method = "rpi"

        if !ok {
            updateRow(rowID) { $0.message = l10n.t("status.rpiSilent") }
            // Split by the REAL file size: header/scan metadata can be wrong.
            let realSize = (try? FileManager.default.attributesOfItem(atPath: game.path)[.size]
                as? NSNumber)??.int64Value ?? info.packageSize
            let pieces = PS4Installer.splitCount(fileSize: realSize)
            server.unregisterPieces(id: id)
            server.registerPieces(id: id, path: game.path, count: pieces)

            let manifest: String
            if pieces > 1 {
                let host = pcIP
                manifest = PS4Installer.buildManifest(
                    urlForPiece: { server.url(host: host, id: RangeHTTPServer.pieceIdentifier(id, $0)) },
                    fileSize: info.packageSize,
                    pieces: pieces,
                    digest: info.digest
                )
            } else {
                manifest = PS4Installer.buildManifest(url: url,
                                                      fileSize: info.packageSize,
                                                      digest: info.digest)
            }
            server.registerManifest(manifest, for: id)
            let manifestURL = server.manifestURL(host: pcIP, id: id)
            let descriptor = PS4PackageDescriptor(
                url: url,
                size: info.packageSize,
                digest: info.digest,
                title: info.title,
                titleId: info.titleId,
                contentId: info.contentId,
                contentType: info.contentType,
                iconData: info.iconData
            )
            let goldHen = await ps4.pushGoldHen(host: psIP, pcAddress: pcIP,
                                                url: manifestURL, descriptor: descriptor)
            method = "goldhen"
            ok = goldHen.0
            reply = goldHen.1
        }
        var sentID: String? = nil
        if ok {
            sentID = rowID
        }
        log("[\(method)] ok=\(ok) url=\(url) reply=\(reply)")

        guard ok else {
            fail(rowID: rowID, message: Format.short(reply, limit: 120))
            status = l10n.t("status.ps4PushFailed", method, Format.short(reply, limit: 160))
            return
        }
        guard let rowID = sentID else { return }
        activeIDs[rowID] = id
        activeIdle[rowID] = 0
        activeSince[rowID] = Date()
        // Re-resolve: the row can be removed or moved while `push` was awaited.
        updateRow(rowID) { $0.message = l10n.t("status.queuedOnPs4", method) }
        updateQueueLabel()
    }

    /// Full PKG header for the GoldHEN wire format; falls back to library fields.
    private static func buildPkgInfo(_ game: GameItem) -> PkgInfo {
        if let info = PkgReader.read(url: URL(fileURLWithPath: game.path)) { return info }
        return PkgInfo(title: game.title,
                       contentId: game.contentId,
                       titleId: game.titleId,
                       version: game.version,
                       platform: game.platform,
                       packageSize: game.sizeBytes,
                       iconData: game.iconData)
    }

    // MARK: - Monitor

    private func monitorTick() {
        guard let server else { return }
        let snapshot = activeIDs
        var done: [String] = []
        var giveUp: [String] = []
        var stalled: [String] = []
        var totalSize: Int64 = 0
        var totalServed: Int64 = 0

        for (rowID, urlID) in snapshot {
            guard let index = index(of: rowID) else { continue }
            let size = queue[index].game.sizeBytes
            let delta = server.servedBytes(for: urlID)
            totalSize += size
            totalServed += min(delta, size)

            if Self.isDownloaded(delta: delta, size: size) {
                let idle = (activeIdle[rowID] ?? 0) + 1
                activeIdle[rowID] = idle
                if idle >= Self.doneSamples { done.append(rowID) }
            } else {
                activeIdle[rowID] = 0
                if delta == 0, let since = activeSince[rowID],
                   Date().timeIntervalSince(since) >= 30 * 60 {
                    giveUp.append(rowID)
                } else if delta > 0 {
                    if let previous = stallSince[rowID], previous.1 == delta {
                        if Date().timeIntervalSince(previous.0) >= 10 * 60 { stalled.append(rowID) }
                    } else {
                        stallSince[rowID] = (Date(), delta)
                    }
                }
            }

            if !done.contains(rowID), !giveUp.contains(rowID), !stalled.contains(rowID) {
                let speed = delta == 0 ? "" : trackSpeed(rowID, delta)
                queue[index].percent = size <= 0 ? 1 : min(1, Double(delta) / Double(size))
                queue[index].bytesSent = delta
                queue[index].speed = speed
                queue[index].message = delta == 0
                    ? l10n.t("status.queuedOnConsole")
                    : "\(Format.bytes(delta)) / \(Format.bytes(size))" + (speed.isEmpty ? "" : " • \(speed)")
            }
        }

        let settled = done + giveUp + stalled
        for rowID in settled {
            activeIDs.removeValue(forKey: rowID)
            activeIdle.removeValue(forKey: rowID)
            activeSince.removeValue(forKey: rowID)
            stallSince.removeValue(forKey: rowID)
            speedSamples.removeValue(forKey: rowID)
        }
        for rowID in done { markSent(rowID, message: l10n.t("status.sentToConsoleQueue")) }
        for rowID in giveUp {
            guard let index = index(of: rowID) else { continue }
            queue[index].state = .failed
            queue[index].message = l10n.t("status.consoleNeverPulled")
            queue[index].canResume = true
        }
        for rowID in stalled {
            guard let index = index(of: rowID) else { continue }
            queue[index].state = .failed
            queue[index].message = l10n.t("status.downloadStalled")
            queue[index].canResume = true
        }
        if !settled.isEmpty { updateQueueLabel() }

        let remainingIDs = activeIDs
        var remainingSize: Int64 = 0
        var remainingServed: Int64 = 0
        for (rowID, urlID) in remainingIDs {
            guard let entry = row(id: rowID) else { continue }
            remainingSize += entry.game.sizeBytes
            remainingServed += min(server.servedBytes(for: urlID), entry.game.sizeBytes)
        }
        updateEta(activeCount: remainingIDs.count,
                  totalSize: remainingSize,
                  totalServed: remainingServed)
        passiveProgressTick()
    }

    /// 1 MiB tolerance: a client disconnect on the last chunk leaves the
    /// counter up to one buffer short of a fully downloaded file.
    private static func isDownloaded(delta: Int64, size: Int64) -> Bool {
        guard size > 0 else { return true }
        if delta >= size { return true }
        return size - delta <= completionTolerance
    }

    private func trackSpeed(_ rowID: String, _ bytes: Int64) -> String {
        var samples = speedSamples[rowID] ?? []
        let now = Date()
        samples.append((now, bytes))
        if samples.count > 4 { samples.removeFirst(samples.count - 4) }
        speedSamples[rowID] = samples
        guard samples.count >= 2, let first = samples.first else { return "" }
        let elapsed = now.timeIntervalSince(first.0)
        guard elapsed >= 1 else { return "" }
        return Format.speed(max(0, Double(bytes - first.1) / elapsed))
    }

    /// Display-only progress for rows the console pulls while this app has
    /// parked them: shows bytes/speed/bar without touching the state machine.
    private func passiveProgressTick() {
        guard let server else { return }
        var updated: [(String, Int64, Int64)] = []
        for key in passiveLast.keys where !queue.contains(where: { $0.id == key }) {
            passiveLast.removeValue(forKey: key)
        }
        for entry in queue {
            guard !entry.isFinished, !activeIDs.keys.contains(entry.id),
                  entry.state == .queued || entry.state == .sending,
                  let urlID = library.knownIdentifier(path: entry.game.path) else { continue }
            let delta = server.servedBytes(for: urlID)
            guard delta > 0, passiveLast[entry.id] != delta else { continue }
            passiveLast[entry.id] = delta
            updated.append((entry.id, delta, entry.game.sizeBytes))
        }
        for (rowID, delta, size) in updated {
            guard let index = index(of: rowID) else { continue }
            let speed = trackSpeed(rowID, delta)
            queue[index].percent = size <= 0 ? 1 : min(1, Double(delta) / Double(size))
            queue[index].speed = speed
            queue[index].message = "\(Format.bytes(delta)) / \(Format.bytes(size)) (\(l10n.t("status.consolePulling")))"
                + (speed.isEmpty ? "" : " • \(speed)")
        }
    }

    private var etaLastTime = Date()
    private var etaLastServed: Int64 = 0
    private var lastSpeed: Double = 0

    private func updateEta(activeCount: Int, totalSize: Int64, totalServed: Int64) {
        guard activeCount > 0 else {
            speedText = ""
            etaText = ""
            lastSpeed = 0
            etaLastServed = 0
            etaLastTime = Date()
            return
        }
        let now = Date()
        let elapsed = now.timeIntervalSince(etaLastTime)
        if elapsed >= 1 {
            lastSpeed = max(0, Double(totalServed - etaLastServed) / elapsed)
            etaLastTime = now
            etaLastServed = totalServed
        }
        speedText = Format.speed(lastSpeed)
        if totalSize > 0, totalServed >= totalSize {
            etaText = l10n.t("status.finishing")
        } else if lastSpeed > 0 {
            etaText = Format.eta(Double(totalSize - totalServed) / lastSpeed)
        } else {
            etaText = totalServed > 0 ? l10n.t("status.stalledEta") : l10n.t("status.calculating")
        }
    }

    // MARK: - Row actions

    func togglePause(_ rowID: String) {
        guard let index = index(of: rowID) else { return }
        let entry = queue[index]
        if entry.state == .copying {
            Task { await toggleCopyPause(rowID) }
            return
        }
        if !entry.isPaused {
            queue[index].isPaused = true
            if let urlID = activeIDs.removeValue(forKey: rowID) {
                server?.revoke(urlID)
                activeIdle.removeValue(forKey: rowID)
                activeSince.removeValue(forKey: rowID)
                speedSamples.removeValue(forKey: rowID)
                stallSince.removeValue(forKey: rowID)
                queue[index].canResume = true
            }
            queue[index].message = l10n.t("status.paused")
        } else {
            // Resume. `resumeRow` re-queues the row and restarts the worker, so
            // don't fall through into the branches below.
            queue[index].isPaused = false
            if entry.canResume {
                resumeRow(rowID)
            } else {
                // Paused before it ever reached the console (still queued):
                // just put it back in line.
                queue[index].message = l10n.t("status.waiting")
                if !runQueue.contains(rowID) { runQueue.append(rowID) }
                if !running { startWorker() }
            }
        }
        updateQueueLabel()
    }

    private func toggleCopyPause(_ rowID: String) async {
        guard let index = index(of: rowID) else { return }
        let paused = !queue[index].isPaused
        let ok = await client.setPullPaused(host: psIP, paused: paused)
        guard ok else {
            status = l10n.t("status.pauseSignalFailed")
            return
        }
        queue[index].isPaused = paused
        queue[index].message = paused ? l10n.t("status.paused") : l10n.t("queue.state.copying")
        updateQueueLabel()
    }

    /// Resume without a new push: the same URL is served again (counter kept)
    /// so the console continues from its last byte.
    func resumeRow(_ rowID: String) {
        guard let index = index(of: rowID) else { return }
        // Re-derive the id instead of `knownIdentifier(path:)`: the lookup table
        // is only populated as a side effect of register(), so after a pause
        // (which drops the row from `activeIDs`) it can be empty and the resume
        // would silently do nothing. `identifier(path:size:)` is a pure hash of
        // path+size, so recomputing it always yields the same id the console
        // already knows.
        let game = queue[index].game
        let urlID = library.identifier(path: game.path, size: game.sizeBytes)
        // Re-arm the file source for the same id WITHOUT zeroing the served
        // counter: the console resumes from its last byte, which is the whole
        // point of pausing. (A fresh `register(game:)` would call
        // `resetServed` and restart the transfer from 0 — the upstream
        // `ResumeRow` deliberately keeps the counter.)
        if !activeIDs.values.contains(urlID) { server?.resetServed(urlID) }
        if let source = RangeSource(fileAtPath: game.path) {
            server?.register(source, for: urlID)
        }
        server?.unrevoke(urlID)

        activeIDs[rowID] = urlID
        activeIdle[rowID] = 0
        // Keep `activeSince` in the past: the monitor treats a row as stalled
        // after 10 minutes without bytes, and a long pause must not make the
        // resumed row look stalled the moment it comes back.
        activeSince[rowID] = Date().addingTimeInterval(-Self.gateSkipAfter)
        stallSince.removeValue(forKey: rowID)
        speedSamples.removeValue(forKey: rowID)
        queue[index].canResume = false
        queue[index].isPaused = false
        // Stay `.sending` — matching upstream `ResumeRow`. The row is back in
        // `activeIDs`, so the worker keeps monitoring this same URL; putting it
        // back to `.queued` would make the worker re-push it and restart the
        // console's download from zero.
        queue[index].state = .sending
        queue[index].message = l10n.t("status.resumingRow")
        // Deliberately NOT re-queued: the row is live again through `activeIDs`,
        // so the worker just keeps monitoring the same URL. Adding it back to
        // `runQueue` would make the worker push it a second time and restart the
        // console's download from zero. Mirrors upstream `ResumeRow`.
        updateQueueLabel()
        if !running { startWorker() }
    }

    /// ⟳ Reinstall of a failed row: straight to the front with a fresh counter.
    func resendRow(_ rowID: String) {
        guard let index = index(of: rowID), queue[index].state == .failed else { return }
        runQueue.removeAll { $0 == rowID }
        runQueue.insert(rowID, at: 0)
        queue[index].isPaused = false
        queue[index].state = .queued
        queue[index].message = l10n.t("status.waitingRetry")
        queue[index].percent = 0
        queue[index].bytesSent = 0
        queue[index].speed = ""
        queue[index].canResume = false
        updateQueueLabel()
        if !running { startWorker() }
    }

    func removeRow(_ rowID: String) {
        guard let index = index(of: rowID) else { return }
        let entry = queue[index]
        // Copy rows live on the receiver: only /api/pull/cancel actually stops
        // the bytes. Dropping the row alone would leave the console pulling
        // with nobody watching.
        if entry.state == .copying {
            copyStop = true
            let address = psIP
            Task { _ = await client.cancelPull(host: address) }
            queue.remove(at: index)
            updateQueueLabel()
            status = l10n.t("status.copyCancelled")
            return
        }
        let wasPending = runQueue.contains(rowID)
        runQueue.removeAll { $0 == rowID }
        let revoked = activeIDs.removeValue(forKey: rowID)
        if let revoked {
            server?.revoke(revoked)
            activeIdle.removeValue(forKey: rowID)
            activeSince.removeValue(forKey: rowID)
            speedSamples.removeValue(forKey: rowID)
            stallSince.removeValue(forKey: rowID)
        }
        if wasPending || revoked == nil {
            queue.remove(at: index)
            updateQueueLabel()
            status = wasPending ? l10n.t("status.removedFromQueue") : l10n.t("status.removed")
            return
        }
        queue[index].state = .failed
        queue[index].message = l10n.t("queue.state.cancelled")
        queue[index].canResume = true
        updateQueueLabel()
        status = l10n.t("status.cancelled")
    }

    /// ▲▼ reorder. Only rows that are still queued (not yet handed to the
    /// sender) can move, on PS4 and PS5 alike — `runQueue` is the send order
    /// and does not depend on the console generation.
    func moveRow(_ rowID: String, by direction: Int) {
        guard runQueue.contains(rowID),
              let index = index(of: rowID) else {
            status = l10n.t("status.onlyQueuedReorder")
            return
        }
        var target = index + direction
        while target >= 0 && target < queue.count && !runQueue.contains(queue[target].id) {
            target += direction
        }
        guard target >= 0, target < queue.count else { return }
        queue.move(fromOffsets: IndexSet(integer: index), toOffset: target > index ? target + 1 : target)
        runQueue.removeAll { $0 == rowID }
        var position = 0
        for entry in queue {
            if entry.id == rowID { break }
            if runQueue.contains(entry.id) { position += 1 }
        }
        runQueue.insert(rowID, at: min(position, runQueue.count))
        updateQueueLabel()
    }

    func togglePauseAll() {
        let live = queue.filter {
            !$0.isFinished && !$0.isPaused
                && ($0.state == .queued || $0.state == .sending || $0.state == .copying)
        }
        if !live.isEmpty {
            for entry in live { togglePause(entry.id) }
            status = l10n.t("status.pausedAll")
            updateQueueLabel()
            return
        }
        copyStop = false
        var resumeCopy = false
        for index in queue.indices {
            guard !queue[index].isFinished else { continue }
            let wasCopyPaused = queue[index].state == .copying && queue[index].isPaused
            queue[index].isPaused = false
            // A row that was mid-transfer when paused is still in `activeIDs`
            // with a resumable URL: leave it `.sending` so the console
            // continues from its last byte. Only rows the worker has to (re)push
            // go back to `.queued` — matches upstream `TogglePauseAll`.
            if queue[index].state == .sending, activeIDs[queue[index].id] != nil {
                queue[index].message = l10n.t("status.resumingRow")
            } else if queue[index].state == .queued || queue[index].state == .sending {
                if !runQueue.contains(queue[index].id) {
                    runQueue.append(queue[index].id)
                }
                if queue[index].state == .sending {
                    queue[index].state = .queued
                    queue[index].message = l10n.t("status.waiting")
                }
            }
            if wasCopyPaused {
                queue[index].message = l10n.t("queue.state.copying")
                resumeCopy = true
            }
        }
        if resumeCopy {
            let address = psIP
            Task { _ = await client.setPullPaused(host: address, paused: false) }
        }
        updateQueueLabel()
        if !running { startWorker() }
        status = l10n.t("status.resumeAll")
    }

    /// Finished rows go; orphaned rows (queued with no worker behind them) go
    /// too. Active downloads are untouched.
    func clearDone() {
        for index in queue.indices.reversed() {
            let entry = queue[index]
            guard entry.isFinished else { continue }
            queue.remove(at: index)
            runQueue.removeAll { $0 == entry.id }
            activeIDs.removeValue(forKey: entry.id)
            speedSamples.removeValue(forKey: entry.id)
            passiveLast.removeValue(forKey: entry.id)
        }
        updateQueueLabel()
        status = l10n.t("status.clearedFinished")
    }

    // MARK: - Icon lookup

    /// Cover art for a library card or a queue row: the item's own icon, else
    /// the base game's from the same family.
    ///
    /// Goes through `library.effectiveIcon(for:)` rather than filtering `games`
    /// here, because `games` is the *filtered* list — a DLC whose base game is
    /// currently hidden by the search box would lose its fallback art. The
    /// library box holds the full, lock-protected set and is also what
    /// `pushOne` uses to register the icon the console displays, so cards,
    /// queue rows and the console all agree.
    func icon(for item: GameItem) -> Data? {
        library.effectiveIcon(for: item)
    }

    // MARK: - Queue helpers

    private func index(of rowID: String) -> Int? {
        queue.firstIndex { $0.id == rowID }
    }

    private func row(id rowID: String) -> QueueEntry? {
        index(of: rowID).map { queue[$0] }
    }

    private func fail(rowID: String, message: String) {
        // The row may have been removed (or reordered) while an `await` was in
        // flight, so the index captured before suspending can be stale — and
        // out of bounds. Re-resolve by id and bail if the row is gone.
        guard index(of: rowID).map(queue.indices.contains) == true else { return }
        updateRow(rowID) { row in
            row.state = .failed
            row.message = message
            row.canResume = true
            row.isPaused = false
        }
        activeIDs.removeValue(forKey: rowID)
        updateQueueLabel()
    }

    /// Mutate a queue row looked up fresh by id. Returns false when the row no
    /// longer exists, so callers never touch a stale index.
    @discardableResult
    private func updateRow(_ rowID: String, _ body: (inout QueueEntry) -> Void) -> Bool {
        guard let i = index(of: rowID), queue.indices.contains(i) else { return false }
        body(&queue[i])
        return true
    }

    private func markSent(_ rowID: String, message: String) {
        guard let index = index(of: rowID) else { return }
        let title = queue[index].game.title
        queue[index].state = .done
        queue[index].percent = 1
        queue[index].bytesSent = queue[index].game.sizeBytes
        queue[index].speed = ""
        queue[index].message = message
        queue[index].isPaused = false
        queue[index].canReorder = false
        queue[index].canResume = false
        if index < queue.count - 1 {
            let entry = queue.remove(at: index)
            queue.append(entry)
        }
        updateQueueLabel()
        Notifier.notify(title: l10n.t("notify.sentTitle"), body: "\(title) — \(message)")
    }

    private func updateQueueLabel() {
        let done = queue.filter { $0.state == .done }.count
        let failed = queue.filter { $0.state == .failed }.count
        queueLabel = queue.isEmpty
            ? l10n.t("queue.empty")
            : "\(done)/\(queue.count) sent" + (failed > 0 ? ", \(failed) failed" : "")

        // Any row that has not started sending yet can be reordered: `runQueue`
        // is the send order and is independent of the console generation, so
        // this is just as valid on PS5 (concurrent) as in PS4 sequential mode.
        // Rows that are already sending/copying, or finished, are excluded —
        // their position is no longer theirs to change.
        for index in queue.indices {
            queue[index].canReorder = !queue[index].isFinished
                && queue[index].state == .queued
                && !queue[index].isPaused
        }
        let anyRunning = queue.contains {
            !$0.isFinished && !$0.isPaused
                && ($0.state == .queued || $0.state == .sending || $0.state == .copying)
        }
        pauseAllLabel = anyRunning ? l10n.t("queue.pauseAll") : l10n.t("queue.resumeAll")

        guard !queue.isEmpty else { totalProgress = 0; return }
        let finished = queue.filter { $0.state == .done }.count
        let active = queue.filter { !$0.isFinished }
        let activeSum = active.reduce(0.0) { $0 + $1.percent }
        totalProgress = (Double(finished) + activeSum) / Double(queue.count)
    }

    // MARK: - Copy images to /data/homebrew

    func copySelection() {
        let picked = games.filter { selection.contains($0.id) && $0.role == .image }
        Task { await copyImages(picked) }
    }

    func copyImages(_ picked: [GameItem]) async {
        let items = picked.filter { $0.role == .image && !$0.isFolder }
        guard !items.isEmpty else {
            status = l10n.t("status.noImageSelection")
            return
        }
        guard !psIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = l10n.t("status.noConsoleAddress")
            return
        }
        guard !pcIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = l10n.t("status.noPcAddress")
            return
        }
        guard ensureServer(), let server else { return }

        copyStop = false
        var started = 0
        for game in items {
            let id = register(game: game)
            server.unrevoke(id)
            let url = server.url(host: pcIP, id: id)
            let remote = remoteDirectory + "/" + game.fileName

            var resume = false
            if let remoteStatus = await client.stat(host: psIP, remotePath: remote),
               remoteStatus.exists, remoteStatus.size >= 0 {
                let partial = remoteStatus.size > 0 && remoteStatus.size < game.sizeBytes
                let complete = game.sizeBytes > 0 && remoteStatus.size == game.sizeBytes
                let prompt = CopyPrompt(fileName: game.fileName,
                                        remoteText: Format.bytes(remoteStatus.size),
                                        localText: Format.bytes(game.sizeBytes),
                                        canResume: partial,
                                        complete: complete)
                status = complete ? l10n.t("status.alreadyThere", game.title) : status
                let choice = await askCopy(prompt)
                switch choice {
                case .cancel:
                    status = l10n.t("status.skipped", game.title)
                    continue
                case .resume:
                    resume = true
                case .overwrite:
                    resume = false
                }
            }

            status = l10n.t("status.copying", game.title)
            let reply = await client.pull(host: psIP, url: url, remotePath: remote, resume: resume)
            log("pull \(game.title) url=\(url) started=\(reply.ok) reply=\(reply.body)")
            guard reply.ok else {
                status = l10n.t("status.copyFailed", game.title, copyHint(reply.body))
                continue
            }
            started += 1
            let entry = QueueEntry(game: game,
                                   state: .copying,
                                   message: resume ? "resuming…" : "copying…")
            queue.append(entry)
            updateQueueLabel()
            await followCopy(rowID: entry.id, remotePath: remote, game: game)
        }

        if started > 0 {
            status = started == items.count
                ? l10n.t("status.copyStarted", started)
                : l10n.t("status.copyStartedPartial", started, items.count, items.count - started)
        }
    }

    /// Poll the receiver's pull progress so a 36 GB image does not look dead.
    private func followCopy(rowID: String, remotePath: String, game: GameItem) async {
        var lastGot: Int64 = 0
        var lastTime = Date()
        for _ in 0..<7200 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Every await below can let the user remove/reorder the row, so
            // re-resolve by id each time instead of trusting a saved index.
            guard index(of: rowID) != nil else { return }
            guard let progress = await client.pullProgress(host: psIP) else { continue }
            if !progress.active {
                if copyStop {
                    updateRow(rowID) {
                        $0.state = .failed
                        $0.message = l10n.t("status.stoppedPartial")
                    }
                    updateQueueLabel()
                    return
                }
                // Worker done (or died fast) — verify by size, never trust
                // silence: compare remote against local bytes.
                if let remote = await client.stat(host: psIP, remotePath: remotePath),
                   remote.exists, game.sizeBytes > 0, remote.size == game.sizeBytes {
                    markSent(rowID, message: Format.bytes(remote.size) + " " + l10n.t("queue.verified"))
                } else if let remote = await client.stat(host: psIP, remotePath: remotePath),
                          remote.exists {
                    updateRow(rowID) {
                        $0.state = .failed
                        $0.message = l10n.t("status.sizeMismatch", Format.bytes(remote.size))
                    }
                    updateQueueLabel()
                } else {
                    updateRow(rowID) {
                        $0.state = .failed
                        $0.message = l10n.t("status.notOnConsole")
                    }
                    updateQueueLabel()
                }
                return
            }
            let now = Date()
            let elapsed = now.timeIntervalSince(lastTime)
            let bps = elapsed > 0.5 && progress.receivedBytes >= lastGot
                ? Double(progress.receivedBytes - lastGot) / elapsed
                : -1
            lastGot = progress.receivedBytes
            lastTime = now

            let want = progress.totalBytes
            guard updateRow(rowID, { row in
                row.percent = want > 0
                    ? min(1, Double(progress.receivedBytes) / Double(want))
                    : 0
                row.message = progress.paused
                    ? l10n.t("status.paused")
                    : (want > 0
                        ? "\(Format.bytes(progress.receivedBytes)) / \(Format.bytes(want))"
                        : Format.bytes(progress.receivedBytes))
            }) else { return }   // row removed while we were polling
            if progress.paused {
                speedText = l10n.t("status.paused")
                etaText = ""
            } else if bps >= 0 {
                speedText = Format.speed(bps)
                etaText = bps > 0 && want > progress.receivedBytes
                    ? Format.eta(Double(want - progress.receivedBytes) / bps)
                    : ""
            }
        }
        if let index = index(of: rowID), queue[index].state == .copying {
                queue[index].state = .failed
                queue[index].message = l10n.t("status.stalledCopy")
                updateQueueLabel()
        }
        if activeIDs.isEmpty {
            speedText = ""
            etaText = ""
        }
    }

    /// Translate a pull reply into an actionable hint.
    private func copyHint(_ reply: String) -> String {
        if reply.contains("unknown endpoint") {
            return l10n.t("status.pullUnknownEndpoint")
        }
        if reply.contains("test build") {
            return l10n.t("status.pullTestBuild")
        }
        if reply.contains("bad url/path") {
            return l10n.t("status.pullBadUrl", Format.short(reply, limit: 60))
        }
        return Format.short(reply, limit: 60)
    }

    private var remoteDirectory: String {
        let directory = remoteDir.trimmingCharacters(in: .whitespacesAndNewlines)
        if directory.isEmpty { return "/data/homebrew" }
        return directory.hasSuffix("/") ? String(directory.dropLast()) : directory
    }

    // MARK: - Update check

    /// Kick off the silent launch check, but only when the user allows it.
    func startUpdateCheckIfEnabled() {
        guard updateCheck else { return }
        Task { await checkForUpdate() }
    }

    /// Query GitHub for a newer release. Failures are swallowed:
    /// `updateAvailable` simply stays false rather than annoying an offline
    /// or rate-limited user.
    func checkForUpdate() async {
        guard !updateChecking else { return }
        updateChecking = true
        defer { updateChecking = false }
        let info = await UpdateService.checkForUpdate()
        updateAvailable = info.available
        updateLatestVersion = info.latestVersion
        updateReleaseURL = info.releaseURL
    }

    /// Toggle automatic checking and persist the choice.
    func setUpdateCheck(_ enabled: Bool) {
        updateCheck = enabled
        persist()
        if enabled { Task { await checkForUpdate() } }
    }

    /// Open the release page in the default browser.
    func openUpdate() {
        guard let url = updateReleaseURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Dialogs

    func showAbout() { sheet = .about }
    func showGuide() { sheet = .guide }

    func closeAbout() {
        sheet = nil
        if !aboutShown {
            aboutShown = true
            persist()
            Task { await autoDetect() }
        }
    }

    private func askSwitch(_ prompt: SwitchPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            switchContinuation = continuation
            sheet = .switchConsole(prompt)
        }
    }

    func resolveSwitch(_ value: Bool) {
        sheet = nil
        let continuation = switchContinuation
        switchContinuation = nil
        continuation?.resume(returning: value)
    }

    private func askCopy(_ prompt: CopyPrompt) async -> CopyChoice {
        await withCheckedContinuation { continuation in
            copyContinuation = continuation
            sheet = .copyChoice(prompt)
        }
    }

    func resolveCopy(_ choice: CopyChoice) {
        sheet = nil
        let continuation = copyContinuation
        copyContinuation = nil
        continuation?.resume(returning: choice)
    }

    // MARK: - Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        if let message = LoginItemManager.setEnabled(enabled) {
            status = message
        }
        launchAtLogin = LoginItemManager.isEnabled
    }

    // MARK: - Diagnostics log

    private func log(_ line: String) {
        let directory = store.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("push-debug.log")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withInternetDateTime])
        let text = "\(stamp) \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// ISO8601 helper (the formatter is not Sendable, so it is created per call).
extension ISO8601DateFormatter {
    static func string(from date: Date, timeZone: TimeZone,
                       formatOptions: ISO8601DateFormatter.Options) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = formatOptions
        return formatter.string(from: date)
    }
}
