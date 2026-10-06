import Darwin
import Foundation

public enum RangeHTTPServerError: Error, Sendable, LocalizedError {
    case socketFailed(String)
    case bindFailed(String)
    case listenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .socketFailed(let detail): return "socket failed — \(detail)"
        case .bindFailed(let detail): return "bind failed — \(detail)"
        case .listenFailed(let detail): return "listen failed — \(detail)"
        }
    }
}

/// Minimal LAN file server with byte-range (206) support so the console
/// downloader can resume and segment downloads.
///
/// Raw sockets, no admin URL reservation. Serves one file (`/pkg`) or a set of
/// files (`/pkg/{id}`), plus `/catalog`, `/icon/{id}` and `/json/{id}.json`,
/// and reports served bytes for progress bars.
public final class RangeHTTPServer: @unchecked Sendable {
    public static let defaultPort = 9898
    public static let defaultIdentifier = "pkg"
    /// Requests served on one keep-alive connection before it is dropped.
    public static let maxKeepAliveRequests = 200
    /// Guard against unbounded header accumulation from a broken client.
    public static let maxRequestHeadBytes = 32768

    public let port: Int
    /// Registered id → path (immutable; extra entries can be served through
    /// `register(_:for:)`).
    public let files: [String: String]

    private let lock = NSLock()
    private let state = State()

    /// All mutable server state; only touched while `lock` is held.
    private final class State {
        var sources: [String: RangeSource] = [:]
        var pieces: [String: [String]] = [:]
        var revoked: Set<String> = []
        var servedByID: [String: Int64] = [:]
        var icons: [String: Data] = [:]
        var manifests: [String: Data] = [:]
        var served: Int64 = 0
        var active: Int = 0
        var bufferSize = 256 * 1024
        var onProgress: (@Sendable (Int64, Int64) -> Void)?
        var onFileRequested: (@Sendable (String) -> Void)?
        var onRequestLog: (@Sendable (String) -> Void)?
        var catalogProvider: (@Sendable () -> [CatalogEntry])?
        var listenerFD: Int32 = -1
        var acceptSource: DispatchSourceRead?
        var connections: Set<Int32> = []
        var running = false
    }

    public init(files: [String: String], port: Int = defaultPort) {
        self.files = files
        self.port = port
    }

    public convenience init(fileAtPath path: String, port: Int = defaultPort) {
        self.init(files: [Self.defaultIdentifier: path], port: port)
    }

    deinit { stop() }

    // MARK: - Configuration

    /// Per-write copy buffer: 256 KB keeps 16 parallel receiver segments on a
    /// small heap; raise it on desktop for line-rate pushes.
    public var copyBufferSize: Int {
        get { withState { $0.bufferSize } }
        set { withState { $0.bufferSize = newValue } }
    }

    /// Called after every copied chunk: `(servedBytesTotal, resourceSize)`.
    public var onProgress: (@Sendable (Int64, Int64) -> Void)? {
        get { withState { $0.onProgress } }
        set { withState { $0.onProgress = newValue } }
    }

    /// Called when the console requests an id (start of a download).
    public var onFileRequested: (@Sendable (String) -> Void)? {
        get { withState { $0.onFileRequested } }
        set { withState { $0.onFileRequested = newValue } }
    }

    /// Diagnostics sink for every request line.
    public var onRequestLog: (@Sendable (String) -> Void)? {
        get { withState { $0.onRequestLog } }
        set { withState { $0.onRequestLog = newValue } }
    }

    /// Library rows served at `GET /catalog`.
    public var catalogProvider: (@Sendable () -> [CatalogEntry])? {
        get { withState { $0.catalogProvider } }
        set { withState { $0.catalogProvider = newValue } }
    }

    // MARK: - Counters

    public var isRunning: Bool { withState { $0.running } }
    public var servedBytes: Int64 { withState { $0.served } }
    public var activeRequests: Int { withState { $0.active } }

    /// Bytes served for one id, including all of its registered pieces.
    public func servedBytes(for id: String) -> Int64 {
        withState { state in
            var total = state.servedByID[id] ?? 0
            for piece in state.pieces[id] ?? [] {
                total += state.servedByID[piece] ?? 0
            }
            return total
        }
    }

    /// Total bytes across all registered files and sources (queue progress).
    public func totalBytes() -> Int64 {
        withState { state in
            var total: Int64 = 0
            for path in files.values {
                total += RangeSource.sizeOfFile(at: path) ?? 0
            }
            for source in state.sources.values {
                total += source.length
            }
            return total
        }
    }

    /// Size of a registered file, when it exists.
    public func fileSize(for id: String) -> Int64? {
        guard let path = files[id] else { return nil }
        return RangeSource.sizeOfFile(at: path)
    }

    // MARK: - Registration

    /// Cover art served to the console installer UI at `/icon/{id}`.
    public func registerIcon(_ png: Data, for id: String) {
        withState { $0.icons[id] = png }
    }

    public func unregisterIcon(for id: String) {
        withState { $0.icons.removeValue(forKey: id) }
    }

    /// PS4 GoldHEN manifest served at `/json/{id}.json`.
    public func registerManifest(_ json: String, for id: String) {
        withState { $0.manifests[id] = Data(json.utf8) }
    }

    public func unregisterManifest(for id: String) {
        withState { $0.manifests.removeValue(forKey: id) }
    }

    /// Serve `id` from a seekable source instead of a file (direct mode).
    public func register(_ source: RangeSource, for id: String) {
        withState { $0.sources[id] = source }
    }

    public func unregisterSource(for id: String) {
        withState { $0.sources.removeValue(forKey: id) }
    }

    /// Piece id for the i-th split of a multi-piece manifest.
    public static func pieceIdentifier(_ id: String, _ index: Int) -> String {
        "\(id).p\(index)"
    }

    /// Split one file into `count` parallel pieces (BGFT multi-connection
    /// download). Progress and revoke counters follow the parent id.
    public func registerPieces(id: String, path: String, count: Int) {
        unregisterPieces(id: id)
        guard let size = RangeSource.sizeOfFile(at: path) else { return }
        let pieces = max(1, min(count, 16))
        var identifiers: [String] = []
        for index in 0..<pieces {
            let start = size * Int64(index) / Int64(pieces)
            let end = size * Int64(index + 1) / Int64(pieces)
            let identifier = Self.pieceIdentifier(id, index)
            guard let source = RangeSource(fileAtPath: path, sliceOffset: start, sliceLength: end - start) else {
                continue
            }
            withState { $0.sources[identifier] = source }
            identifiers.append(identifier)
        }
        withState { $0.pieces[id] = identifiers }
    }

    /// Drop all piece slices of an id (a re-push registers fresh ones).
    public func unregisterPieces(id: String) {
        let identifiers = withState { $0.pieces.removeValue(forKey: id) } ?? []
        guard !identifiers.isEmpty else { return }
        withState { state in
            for identifier in identifiers {
                state.sources.removeValue(forKey: identifier)
            }
        }
    }

    /// Stop serving one id (404 from now on): the console's in-flight download
    /// errors out instead of continuing silently.
    public func revoke(_ id: String) {
        withState { state in
            state.revoked.insert(id)
            for piece in state.pieces[id] ?? [] {
                state.revoked.insert(piece)
            }
        }
    }

    /// Serve the id again (undo `revoke`, e.g. for a resume).
    public func unrevoke(_ id: String) {
        withState { state in
            state.revoked.remove(id)
            for piece in state.pieces[id] ?? [] {
                state.revoked.remove(piece)
            }
        }
    }

    /// Zero the per-id served counter (fresh push of the same id).
    public func resetServed(_ id: String) {
        withState { state in
            state.servedByID[id] = 0
            for piece in state.pieces[id] ?? [] {
                state.servedByID[piece] = 0
            }
        }
    }

    // MARK: - URLs

    public func url(host: String) -> String {
        "http://\(host):\(port)/\(Self.defaultIdentifier)"
    }

    public func url(host: String, id: String) -> String {
        "http://\(host):\(port)/\(Self.defaultIdentifier)/\(URLEncoding.encodeOnce(id))"
    }

    public func iconURL(host: String, id: String) -> String {
        "http://\(host):\(port)/icon/\(URLEncoding.encodeOnce(id))"
    }

    public func manifestURL(host: String, id: String) -> String {
        "http://\(host):\(port)/json/\(URLEncoding.encodeOnce(id)).json"
    }

    public func catalogURL(host: String) -> String {
        "http://\(host):\(port)/catalog"
    }

    // MARK: - Lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !state.running else { return }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw RangeHTTPServerError.socketFailed(SocketSupport.describeLastError("socket"))
        }
        SocketSupport.setReuseAddress(fd)
        SocketSupport.disableSIGPIPE(fd)
        SocketSupport.setNonBlocking(fd)

        var address = SocketSupport.sockaddrIn(.zero, port: port)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw RangeHTTPServerError.bindFailed(SocketSupport.describeLastError("port \(port)"))
        }
        guard Darwin.listen(fd, 32) == 0 else {
            close(fd)
            throw RangeHTTPServerError.listenFailed(SocketSupport.describeLastError("listen"))
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { close(fd) }

        state.listenerFD = fd
        state.acceptSource = source
        state.running = true
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = state.acceptSource
        let listener = state.listenerFD
        let connections = state.connections
        state.acceptSource = nil
        state.listenerFD = -1
        state.connections = []
        state.running = false
        lock.unlock()

        if let source {
            source.cancel() // cancel handler closes the listener
        } else if listener >= 0 {
            close(listener)
        }
        for fd in connections { close(fd) }
    }

    // MARK: - Accept loop

    private func acceptPendingConnections() {
        let listener = withState { $0.listenerFD }
        guard listener >= 0 else { return }
        while true {
            let connection = Darwin.accept(listener, nil, nil)
            guard connection >= 0 else { return } // EAGAIN: nothing pending
            configure(connection)
            withState { $0.connections.insert(connection) }
            DispatchQueue.global(qos: .userInitiated).async { self.serve(connection) }
        }
    }

    /// Bulk-send tuning: a 4 MB send buffer and Nagle on, so the console pulls
    /// at line rate instead of a few MB/s.
    private func configure(_ fd: Int32) {
        SocketSupport.disableSIGPIPE(fd)
        SocketSupport.setBlocking(fd)
        SocketSupport.setTimeout(fd, seconds: 30)
        var sendBuffer = Int32(4 * 1024 * 1024)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, socklen_t(MemoryLayout<Int32>.size))
        var nagle = Int32(0)
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nagle, socklen_t(MemoryLayout<Int32>.size))
    }

    private func serve(_ fd: Int32) {
        withState { $0.active += 1 }
        defer {
            withState { state in
                state.active -= 1
                state.connections.remove(fd)
            }
            shutdown(fd, SHUT_WR)
            close(fd)
        }

        var handled = 0
        // Bytes already received but not consumed: the console pipelines the
        // next request right behind the previous one on a keep-alive socket.
        var pending: [UInt8] = []
        while handled < Self.maxKeepAliveRequests {
            guard let (head, rest) = readRequestHead(fd, pending: &pending) else { return }
            pending = rest
            let keepAlive = respond(to: head, on: fd)
            if !keepAlive { return }
            handled += 1
        }
    }

    /// Reads until the blank line that terminates the request head.
    /// Returns the parsed head plus every byte that followed it (next request).
    private func readRequestHead(_ fd: Int32, pending: inout [UInt8]) -> (head: HTTPRequestHead, rest: [UInt8])? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var scanStart = 0
        while true {
            if let end = Self.terminatorIndex(in: pending, from: scanStart) {
                let text = String(decoding: pending[0...end + 3], as: UTF8.self)
                let rest = Array(pending[(end + 4)...])
                guard let head = HTTPRequestHead.parse(text) else { return nil }
                return (head, rest)
            }
            scanStart = max(0, pending.count - 3)
            let read = buffer.withUnsafeMutableBytes { raw in
                SocketSupport.receive(fd, into: raw.baseAddress!, length: raw.count)
            }
            guard read > 0 else { return nil }
            pending.append(contentsOf: buffer[0..<read])
            guard pending.count <= Self.maxRequestHeadBytes else { return nil }
        }
    }

    private static func terminatorIndex(in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var index = min(max(0, start), bytes.count - 4)
        while index + 3 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A,
               bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: - Request handling

    /// Serves one request; returns whether the connection may be reused.
    private func respond(to head: HTTPRequestHead, on fd: Int32) -> Bool {
        let keepAlive = head.wantsKeepAlive
        let method = head.method.uppercased()
        log("\(Self.peerAddress(fd)) \(method) \(head.path) in \(head.version)"
            + " conn=\(head.value(for: "Connection") ?? "-") [a=\(activeRequests)]")

        guard method == "GET" || method == "HEAD" else {
            send(fd, HTTPResponseHead.head(
                status: 405,
                reason: "Method Not Allowed",
                headers: [("Content-Length", "0")] + HTTPResponseHead.corsHeaders(),
                keepAlive: false
            ))
            return false
        }
        let isHead = method == "HEAD"
        let path = head.path

        switch path {
        case "/catalog":
            return respondCatalog(on: fd, isHead: isHead, keepAlive: keepAlive)
        case let path where path.hasPrefix("/icon/"):
            return respondIcon(String(path.dropFirst("/icon/".count)), on: fd, isHead: isHead, keepAlive: keepAlive)
        case let path where path.hasPrefix("/json/") && path.hasSuffix(".json"):
            let raw = path.dropFirst("/json/".count).dropLast(".json".count)
            return respondManifest(String(raw), on: fd, isHead: isHead, keepAlive: keepAlive)
        case "/\(Self.defaultIdentifier)":
            return respondPackage(id: Self.defaultIdentifier, head: head, on: fd, isHead: isHead, keepAlive: keepAlive)
        case let path where path.hasPrefix("/\(Self.defaultIdentifier)/"):
            let raw = path.dropFirst("/\(Self.defaultIdentifier)/".count)
            return respondPackage(
                id: URLEncoding.decode(String(raw)),
                head: head,
                on: fd,
                isHead: isHead,
                keepAlive: keepAlive
            )
        default:
            return notFound(on: fd, keepAlive: keepAlive)
        }
    }

    private func notFound(on fd: Int32, keepAlive: Bool) -> Bool {
        log("404")
        guard send(fd, HTTPResponseHead.notFound(keepAlive: keepAlive)) else { return false }
        _ = SocketSupport.sendAll(fd, HTTPResponseHead.notFoundBody)
        return keepAlive
    }

    private func respondCatalog(on fd: Int32, isHead: Bool, keepAlive: Bool) -> Bool {
        let provider = withState { $0.catalogProvider }
        let body = CatalogJSON.data(provider?() ?? [])
        log("catalog 200 (\(body.count) bytes)")
        let head = HTTPResponseHead.head(
            status: 200,
            reason: "OK",
            headers: [
                ("Content-Type", "application/json"),
                ("Content-Length", String(body.count)),
                ("Cache-Control", "no-store"),
            ] + HTTPResponseHead.corsHeaders(),
            keepAlive: keepAlive
        )
        guard send(fd, head) else { return false }
        if !isHead { _ = SocketSupport.sendAll(fd, body) }
        return keepAlive
    }

    private func respondIcon(_ raw: String, on fd: Int32, isHead: Bool, keepAlive: Bool) -> Bool {
        let id = URLEncoding.decode(raw)
        let icon = withState { state -> Data? in
            guard !state.revoked.contains(id), let icon = state.icons[id], !icon.isEmpty else { return nil }
            return icon
        }
        guard let icon else {
            log("icon 404 (\(id))")
            return notFound(on: fd, keepAlive: keepAlive)
        }
        notifyFileRequested(id)
        log("icon 200 (\(id), \(icon.count) bytes)")
        let head = HTTPResponseHead.head(
            status: 200,
            reason: "OK",
            headers: [
                ("Content-Type", "image/png"),
                ("Content-Length", String(icon.count)),
                ("Accept-Ranges", "bytes"),
            ] + HTTPResponseHead.corsHeaders(),
            keepAlive: keepAlive
        )
        guard send(fd, head) else { return false }
        if !isHead { _ = SocketSupport.sendAll(fd, icon) }
        return keepAlive
    }

    private func respondManifest(_ raw: String, on fd: Int32, isHead: Bool, keepAlive: Bool) -> Bool {
        let id = URLEncoding.decode(raw)
        let manifest = withState { state -> Data? in
            guard let manifest = state.manifests[id], !manifest.isEmpty else { return nil }
            return manifest
        }
        guard let manifest else {
            log("manifest 404 (\(id))")
            return notFound(on: fd, keepAlive: keepAlive)
        }
        log("manifest 200 (\(id), \(manifest.count) bytes)")
        let head = HTTPResponseHead.head(
            status: 200,
            reason: "OK",
            headers: [
                ("Content-Type", "application/json"),
                ("Content-Length", String(manifest.count)),
                ("Cache-Control", "no-store"),
            ] + HTTPResponseHead.corsHeaders(),
            keepAlive: keepAlive
        )
        guard send(fd, head) else { return false }
        if !isHead { _ = SocketSupport.sendAll(fd, manifest) }
        return keepAlive
    }

    private func respondPackage(
        id: String,
        head: HTTPRequestHead,
        on fd: Int32,
        isHead: Bool,
        keepAlive: Bool
    ) -> Bool {
        guard let source = resolveSource(for: id) else {
            log("pkg 404 (\(id))")
            return notFound(on: fd, keepAlive: keepAlive)
        }
        notifyFileRequested(id)

        let size = source.length
        let range = HTTPRangeParser.parse(headers: head.values(for: "Range"), size: size)
        log(range.statusCode == 200 ? "pkg 200 \(size)" : "pkg \(range.statusCode) \(range.description)")

        guard send(fd, HTTPResponseHead.bytesResponse(range: range, keepAlive: keepAlive)) else { return false }
        if isHead { return keepAlive } // headers only
        sendBody(id: id, source: source, range: range, on: fd)
        return keepAlive
    }

    private func resolveSource(for id: String) -> RangeSource? {
        let (registered, path) = withState { state -> (RangeSource?, String?) in
            guard !state.revoked.contains(id) else { return (nil, nil) }
            return (state.sources[id], files[id])
        }
        if let registered { return registered }
        if let path { return RangeSource(fileAtPath: path) }
        return nil
    }

    private func sendBody(id: String, source: RangeSource, range: HTTPByteRange, on fd: Int32) {
        guard range.length > 0 else { return }
        let reader: RangeByteReader
        do {
            reader = try source.open(at: range.start)
        } catch {
            log("pkg open failed: \(error)")
            return
        }
        defer { reader.close() }

        let chunkSize = max(64 * 1024, min(copyBufferSize, 4 * 1024 * 1024))
        let progress = withState { $0.onProgress }
        var remaining = range.length
        while remaining > 0 {
            do {
                guard let chunk = try reader.read(upToCount: Int(min(Int64(chunkSize), remaining))),
                      !chunk.isEmpty else {
                    log("pkg EOF, \(remaining) byte(s) left")
                    break
                }
                guard SocketSupport.sendAll(fd, chunk) else {
                    log("pkg send failed")
                    break
                }
                remaining -= Int64(chunk.count)
                // Counting must not depend on a progress handler being set:
                // `progress?(…)` would skip the argument entirely when nil.
                let total = recordServed(id: id, count: Int64(chunk.count))
                progress?(total, range.size)
            } catch {
                log("pkg error: \(error)")
                break
            }
        }
    }

    private func recordServed(id: String, count: Int64) -> Int64 {
        withState { state in
            state.served += count
            state.servedByID[id, default: 0] += count
            return state.served
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func withState<T>(_ body: (State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    @discardableResult
    private func send(_ fd: Int32, _ text: String) -> Bool {
        SocketSupport.sendAll(fd, Array(text.utf8))
    }

    private func log(_ message: String) {
        withState { $0.onRequestLog }?(message)
    }

    private func notifyFileRequested(_ id: String) {
        withState { $0.onFileRequested }?(id)
    }

    private static func peerAddress(_ fd: Int32) -> String {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(fd, $0, &length)
            }
        }
        guard result == 0, let address = SocketSupport.senderAddress(of: storage) else { return "unknown" }
        return address.description
    }
}
