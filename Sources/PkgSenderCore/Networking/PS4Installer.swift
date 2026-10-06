import Darwin
import Foundation

/// PS4 install path detected for one console.
public enum PS4InstallMethod: String, Sendable, CaseIterable, CustomStringConvertible {
    /// Remote Package Installer API on 12800.
    case rpi
    /// GoldHEN Payload Server (9090) + bin injection on 9090/9021/9020.
    case goldhen
    case offline

    public var description: String { rawValue }
}

public enum PS4InstallerError: Error, Sendable, LocalizedError {
    case missingPayload
    case markerNotFound
    case payloadTooShort(needed: Int, available: Int)
    case invalidAddress(String)
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingPayload:
            return "ps4_dpi_payload.bin missing"
        case .markerNotFound:
            return "payload marker not found"
        case .payloadTooShort(let needed, let available):
            return "payload too short for marker patch (\(available) bytes, need \(needed))"
        case .invalidAddress(let address):
            return "bad PC address for payload patch: \(address)"
        case .listenerFailed(let detail):
            return "PC listener failed: \(detail)"
        }
    }
}

/// Everything the PS4 needs to know about a package, ported from
/// `PkgInfo` so the networking layer stays independent of the app models.
public struct PS4PackageDescriptor: Sendable, Hashable {
    /// URL handed to the console (raw PKG for RPI, manifest for GoldHEN).
    public var url: String
    public var size: Int64
    /// PKG header digest (CNT+0xFE0), like DPI's `PkgInfo.Digest`.
    public var digest: String
    public var title: String
    public var titleId: String
    public var contentId: String
    /// Raw category ("gd"/"ac") or an already PS4-prefixed one.
    public var contentType: String
    public var iconData: Data?

    public init(
        url: String = "",
        size: Int64 = 0,
        digest: String = "",
        title: String = "",
        titleId: String = "",
        contentId: String = "",
        contentType: String = "",
        iconData: Data? = nil
    ) {
        self.url = url
        self.size = size
        self.digest = digest
        self.title = title
        self.titleId = titleId
        self.contentId = contentId
        self.contentType = contentType
        self.iconData = iconData
    }
}

public struct PS4InstallResult: Sendable, Hashable {
    public let ok: Bool
    public let method: PS4InstallMethod
    public let reply: String
}

/// PS4 install paths, ported from marcussacana/DirectPackageInstaller:
/// 1) Remote Package Installer API at 12800 (`/api/install`)
/// 2) GoldHEN Payload Server at 9090 + bin injection on 9090/9021/9020.
///
/// The payload binary is **not** loaded from the app bundle: callers pass it
/// in (`payload`) so the core stays usable from tests and from a CLI.
public actor PS4Installer {
    /// `[0xB4 × 6]` placeholder inside the payload: 4 bytes of PC IP plus
    /// 2 bytes of callback port are written over it.
    public static let payloadMarker: [UInt8] = [0xB4, 0xB4, 0xB4, 0xB4, 0xB4, 0xB4]
    public static let binLoaderPorts = [9090, 9021, 9020]
    /// Detection probe cache TTL: long enough to matter for queued pushes,
    /// short enough to notice a freshly started RPI/GoldHEN.
    public static let detectCacheTTL: TimeInterval = 60

    public let payload: Data
    private let client: ConsoleClient
    private var detectCache: [String: (method: PS4InstallMethod, at: Date)] = [:]

    public init(payload: Data, client: ConsoleClient = ConsoleClient()) {
        self.payload = payload
        self.client = client
    }

    // MARK: - Detection

    /// Auto-detect order: RPI → GoldHEN → offline.
    /// - Parameter fresh: skip the cache (Test button) so a stale "offline"
    ///   from before the receiver started cannot mislead.
    public func detect(host: String, fresh: Bool = false) async -> PS4InstallMethod {
        if !fresh, let hit = detectCache[host], Date().timeIntervalSince(hit.at) < Self.detectCacheTTL {
            return hit.method
        }
        let method = await detectUncached(host: host)
        detectCache[host] = (method, Date())
        return method
    }

    private func detectUncached(host: String) async -> PS4InstallMethod {
        if await isRpiOnline(host: host) { return .rpi }
        if await isGoldHenOnline(host: host) { return .goldhen }
        if await canConnectBinLoader(host: host) { return .goldhen } // raw binloader still counts
        return .offline
    }

    public func isRpiOnline(host: String) async -> Bool {
        guard let body = await client.get(host: host, port: 12800, path: "/api", timeout: 3) else { return false }
        return body.contains("Unsupported method") && body.contains("fail")
    }

    public func isGoldHenOnline(host: String) async -> Bool {
        guard let body = await client.get(host: host, port: 9090, path: "/status", timeout: 3) else { return false }
        return body.filter { !$0.isWhitespace }.contains("\"status\":\"ready\"")
    }

    /// True when any binloader port accepts a connection.
    public func canConnectBinLoader(host: String) async -> Bool {
        guard let address = IPv4Address(host) else { return false }
        let ports = Self.binLoaderPorts
        return await SocketSupport.runBlocking {
            ports.contains { port in
                let fd = SocketSupport.connect(to: address, port: port, timeoutMs: 2000)
                guard fd >= 0 else { return false }
                shutdown(fd, SHUT_WR)
                close(fd)
                return true
            }
        }
    }

    /// Per-port diagnosis ("wrong IP / isolated" vs "no service").
    public func diagnose(host: String) async -> String {
        let api = await describe(host: host, port: 12800, path: "/api")
        let status = await describe(host: host, port: 9090, path: "/status")
        let port9021 = await tcpState(host: host, port: 9021)
        let port9020 = await tcpState(host: host, port: 9020)
        return [
            "12800: \(api)",
            "9090: \(status)",
            "9021: \(port9021)",
            "9020: \(port9020)",
        ].joined(separator: " | ")
    }

    private func describe(host: String, port: Int, path: String) async -> String {
        guard await tcpState(host: host, port: port) == "open" else { return "closed" }
        guard let body = await client.get(host: host, port: port, path: path, timeout: 3)?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return "open, HTTP fail" }
        let preview = body.count > 70 ? String(body.prefix(70)) + "…" : body
        return "open HTTP 200 \(preview)"
    }

    private func tcpState(host: String, port: Int) async -> String {
        guard let address = IPv4Address(host) else { return "closed" }
        let open = await SocketSupport.runBlocking {
            SocketSupport.canConnect(to: address, port: port, timeoutMs: 2000)
        }
        return open ? "open" : "closed"
    }

    // MARK: - Manifest

    /// Pieces for BGFT: 4 for 1 GB+, 2 for 256 MB+, else a single piece.
    public static func splitCount(fileSize: Int64) -> Int {
        if fileSize >= 1 << 30 { return 4 }
        if fileSize >= 256 << 20 { return 2 }
        return 1
    }

    /// Single-piece GoldHEN manifest (DPI RegisterJSON shape).
    public static func buildManifest(url: String, fileSize: Int64, digest: String = "") -> String {
        buildManifest(urlForPiece: { _ in url }, fileSize: fileSize, pieces: 1, digest: digest)
    }

    /// GoldHEN manifest JSON. `pieces[]` are parallel BGFT connections; the
    /// payload fetches this manifest and feeds `pieces[]` to BGFT, so the URL
    /// pushed to the console must be this manifest, never the raw PKG (raw
    /// gives BGFT 0x80990033).
    public static func buildManifest(
        urlForPiece: (Int) -> String,
        fileSize: Int64,
        pieces: Int,
        digest: String = ""
    ) -> String {
        let count = max(1, min(pieces, 16))
        var json = "{\"originalFileSize\":\(fileSize)"
        json += ",\"packageDigest\":\"\(JSONText.escapeForConsole(digest))\""
        json += ",\"numberOfSplitFiles\":\(count)"
        json += ",\"pieces\":["
        for index in 0..<count {
            let offset = fileSize * Int64(index) / Int64(count)
            let length = fileSize * Int64(index + 1) / Int64(count) - offset
            if index > 0 { json += "," }
            json += "{\"url\":\"\(JSONText.escapeForConsole(urlForPiece(index)))\""
            json += ",\"fileOffset\":\(offset)"
            json += ",\"fileSize\":\(length)"
            json += ",\"hashValue\":\"0000000000000000000000000000000000000000\"}"
        }
        return json + "]}"
    }

    // MARK: - Payload patching

    /// First index of `marker` inside `data`, or nil.
    public static func index(of marker: [UInt8], in data: Data) -> Int? {
        guard !marker.isEmpty, data.count >= marker.count else { return nil }
        let bytes = [UInt8](data)
        for start in 0...(bytes.count - marker.count) {
            var matched = true
            for offset in 0..<marker.count where bytes[start + offset] != marker[offset] {
                matched = false
                break
            }
            if matched { return start }
        }
        return nil
    }

    /// Copies the payload with the PC IP (4 bytes) and the callback port
    /// (2 bytes, big-endian) written over the marker.
    public static func patchedPayload(
        _ payload: Data,
        pcAddress: String,
        callbackPort: Int
    ) throws -> Data {
        guard !payload.isEmpty else { throw PS4InstallerError.missingPayload }
        guard let marker = index(of: payloadMarker, in: payload) else {
            throw PS4InstallerError.markerNotFound
        }
        let needed = marker + 8
        guard payload.count >= needed else {
            throw PS4InstallerError.payloadTooShort(needed: needed, available: payload.count)
        }
        guard let address = IPv4Address(pcAddress) else {
            throw PS4InstallerError.invalidAddress(pcAddress)
        }
        guard callbackPort > 0, callbackPort <= UInt16.max else {
            throw PS4InstallerError.invalidAddress("callback port \(callbackPort)")
        }

        var patched = payload
        let start = patched.startIndex + marker
        patched.replaceSubrange(start..<(start + 4), with: address.octets)
        let port = UInt16(callbackPort)
        patched.replaceSubrange((start + 4)..<(start + 6), with: [UInt8(port >> 8), UInt8(port & 0xFF)])
        return patched
    }

    /// BGFT wants a PS4-prefixed type (`PS4GD`/`PS4AC`…), like DPI's
    /// `BGFTContentType`. A raw category or an empty one gives 0x80990033.
    public static func normalizedContentType(_ category: String) -> String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasPrefix("PS4") { return trimmed }
        return trimmed.isEmpty ? "PS4GD" : "PS4" + trimmed
    }

    /// The struct the payload reads from the PC callback: u32 length-prefixed
    /// blobs (little-endian) followed by the u64 package size.
    public static func callbackPayload(descriptor: PS4PackageDescriptor, url: String) -> Data {
        let name = descriptor.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? descriptor.titleId
            : descriptor.title
        var bytes = Data()
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        func blob(_ chunk: Data) {
            u32(UInt32(chunk.count))
            bytes.append(chunk)
        }
        u32(1) // new package
        blob(Data(url.utf8))
        blob(Data(name.utf8))
        blob(Data(descriptor.contentId.utf8))
        blob(Data(normalizedContentType(descriptor.contentType).utf8))
        var size = descriptor.size.littleEndian
        withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }
        if let icon = descriptor.iconData, !icon.isEmpty {
            blob(icon)
        } else {
            u32(0)
        }
        return bytes
    }

    // MARK: - Push

    /// Detects the console and pushes through the matching path.
    /// - Parameter manifestURL: GoldHEN manifest URL; falls back to the
    ///   descriptor URL (already a manifest when the caller built one).
    public func push(
        host: String,
        pcAddress: String,
        descriptor: PS4PackageDescriptor,
        manifestURL: String? = nil
    ) async -> PS4InstallResult {
        let method = await detect(host: host)
        switch method {
        case .rpi:
            let (ok, reply) = await pushRPI(host: host, url: descriptor.url, name: descriptor.title)
            return PS4InstallResult(ok: ok, method: .rpi, reply: reply)
        case .goldhen:
            let (ok, reply) = await pushGoldHen(
                host: host,
                pcAddress: pcAddress,
                url: manifestURL ?? descriptor.url,
                descriptor: descriptor
            )
            return PS4InstallResult(ok: ok, method: .goldhen, reply: reply)
        case .offline:
            return PS4InstallResult(
                ok: false,
                method: .offline,
                reply: "no reply on 12800/9090/9021/9020 — enable RPI or GoldHEN Payload Server"
            )
        }
    }

    /// RPI path: `POST /api/install` on 12800.
    public func pushRPI(host: String, url: String, name: String? = nil, iconURL: String? = nil) async -> (Bool, String) {
        let json = ConsoleClient.installRequest(url: url, name: name, iconURL: iconURL)
        guard let body = await client.post(host: host, port: 12800, path: "/api/install", json: json, timeout: 15)
        else { return (false, "no reply on 12800") }
        return (body.contains("\"success\""), body)
    }

    /// GoldHEN path: local callback listener + payload inject + PKG info struct.
    ///
    /// DPI rule: **one** inject per push, never more. The binloader drops
    /// connections often, so connecting and sending is retried — but once the
    /// bytes are on the wire the callback is awaited exactly once. A second
    /// inject would start a duplicate install.
    public func pushGoldHen(
        host: String,
        pcAddress: String,
        url: String,
        descriptor: PS4PackageDescriptor,
        timeout: TimeInterval = 15,
        attempts: Int = 3
    ) async -> (Bool, String) {
        let payloadBytes = payload
        guard !payloadBytes.isEmpty else { return (false, PS4InstallerError.missingPayload.errorDescription ?? "") }

        let patched: Data
        let listenFD: Int32
        do {
            // Bound once: the port is patched into the payload, so every
            // send-attempt shares it and exactly one callback is ever awaited.
            listenFD = await SocketSupport.runBlocking { Self.bindCallbackListener() }
            guard listenFD >= 0 else {
                return (false, PS4InstallerError.listenerFailed("cannot bind a local TCP port").errorDescription ?? "")
            }
            guard let port = await SocketSupport.runBlocking({ Self.listeningPort(listenFD) }) else {
                close(listenFD)
                return (false, PS4InstallerError.listenerFailed("cannot read the local port").errorDescription ?? "")
            }
            patched = try Self.patchedPayload(payloadBytes, pcAddress: pcAddress, callbackPort: port)
        } catch {
            if listenFD >= 0 { close(listenFD) }
            return (false, error.localizedDescription)
        }
        defer { close(listenFD) }

        guard let address = IPv4Address(host) else {
            return (false, PS4InstallerError.invalidAddress(host).errorDescription ?? "")
        }

        // Phase 1 (retried): get the bytes into the binloader.
        let ports = Self.binLoaderPorts
        var lastError = ""
        var injected = false
        for attempt in 1...max(1, attempts) {
            let (sent, error) = await SocketSupport.runBlocking {
                Self.sendPayload(patched, to: address, ports: ports)
            }
            if sent {
                injected = true
                break
            }
            lastError = error
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(2 * attempt) * 1_000_000_000)
            }
        }
        guard injected else {
            return (
                false,
                lastError + " (after \(attempts) tries — re-enable the GoldHEN Payload Server"
                    + " / BinLoader on the console and retry)"
            )
        }

        // Phase 2 (once): wait for the single callback, then hand over the PKG.
        let timeoutMs = Int(max(1, timeout) * 1000)
        let callbackFD = await SocketSupport.runBlocking { SocketSupport.accept(fd: listenFD, timeoutMs: timeoutMs) }
        guard callbackFD >= 0 else {
            return (
                false,
                "payload sent but console did not call back (PC IP / firewall?)"
                    + " — use ⟳ Reinstall, never auto-pushed twice"
            )
        }
        defer {
            shutdown(callbackFD, SHUT_WR)
            close(callbackFD)
        }
        SocketSupport.disableSIGPIPE(callbackFD)
        var noDelay: Int32 = 1
        _ = setsockopt(callbackFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        let bytes = Self.callbackPayload(descriptor: descriptor, url: url)
        let sent = await SocketSupport.runBlocking { SocketSupport.sendAll(callbackFD, bytes) }
        guard sent else { return (false, "callback send failed") }
        return (true, "Package Sent via GoldHEN")
    }

    // MARK: - Socket helpers

    private static func bindCallbackListener() -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return -1 }
        SocketSupport.setReuseAddress(fd)
        SocketSupport.disableSIGPIPE(fd)
        var address = SocketSupport.sockaddrIn(.zero, port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return -1
        }
        guard Darwin.listen(fd, 1) == 0 else {
            close(fd)
            return -1
        }
        return fd
    }

    private static func listeningPort(_ fd: Int32) -> Int? {
        var address = SocketSupport.sockaddrIn(.zero, port: 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func sendPayload(_ data: Data, to address: IPv4Address, ports: [Int]) -> (Bool, String) {
        for port in ports {
            let fd = SocketSupport.connect(to: address, port: port, timeoutMs: 3000)
            guard fd >= 0 else { continue }
            defer {
                shutdown(fd, SHUT_WR)
                close(fd)
            }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = Int32(data.count)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, socklen_t(MemoryLayout<Int32>.size))
            if SocketSupport.sendAll(fd, data) {
                return (true, "")
            }
        }
        return (
            false,
            "binloader closed on \(ports.map(String.init).joined(separator: "/"))"
                + " — re-enable the GoldHEN Payload Server / BinLoader"
        )
    }
}
