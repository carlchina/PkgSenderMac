import Darwin
import Foundation

/// How a console ended up in the discovery result list.
public enum ConsoleDiscoverySource: String, Sendable, CaseIterable {
    /// Answered the UDP beacon **and** verified over HTTP.
    case beacon
    /// Sent a beacon but `/api` did not answer (receiver starting up).
    case beaconUnverified = "beacon-unverified"
    /// Found by TCP sweep, `/api` answered.
    case sweep
    /// Found by TCP sweep, port open but `/api` did not answer.
    case portOpen = "port-open"
}

public struct ConsoleFound: Sendable, Hashable, CustomStringConvertible {
    public let address: String
    /// `nil` when the console does not expose a busy flag.
    public let busy: Bool?
    public let source: ConsoleDiscoverySource

    public init(address: String, busy: Bool?, source: ConsoleDiscoverySource) {
        self.address = address
        self.busy = busy
        self.source = source
    }

    public var description: String {
        "\(address) (\(source.rawValue))"
    }
}

/// Console discovery: UDP beacon first (short timeout), TCP sweep as fallback.
///
/// All valid NICs are swept in parallel over their **real** subnet — nothing
/// here assumes a /24.
public actor NetworkDiscovery {
    public static let receiverPort = 12800
    public static let fallbackReceiverPort = 9090
    public static let beaconPort = 12801
    public static let beaconMagic = "PKGSENDER"
    /// PC announce (reverse direction): while the library is published the PC
    /// broadcasts its catalog endpoint so the console browser finds it without
    /// manual IP entry.
    public static let pcAnnouncePort = 12802
    public static let pcAnnounceMagic = "PKGSENDER-PC"
    /// Safety cap per NIC so a huge subnet cannot stall the sweep.
    public static let maxHostsPerNetwork = 4096

    private let client: ConsoleClient
    private var announceTask: Task<Void, Never>?

    public init(client: ConsoleClient = ConsoleClient()) {
        self.client = client
    }

    // MARK: - Networks

    /// Active IPv4 networks of this Mac (see `LanNetwork.localNetworks`).
    public func localNetworks(includeVirtual: Bool = false) -> [LanNetwork] {
        LanNetwork.localNetworks(includeVirtual: includeVirtual)
    }

    /// Local address on the same subnet as the console.
    public func bestLocalAddress(networks: [LanNetwork], consoleAddress: String?) -> IPv4Address? {
        LanNetwork.bestLocalAddress(networks, consoleAddress: consoleAddress)
    }

    // MARK: - Discovery

    /// Beacon first, sweep as fallback; results merged and deduped by IP.
    public func findConsoles(
        networks: [LanNetwork]? = nil,
        beaconTimeout: TimeInterval = 2,
        progress: (@Sendable (String) -> Void)? = nil,
        onBeacon: (@Sendable (String) -> Void)? = nil
    ) async -> [ConsoleFound] {
        var merged: [String: ConsoleFound] = [:]

        progress?("Listening for receiver beacons…")
        let beacons = await listenForBeacons(duration: beaconTimeout, onBeacon: onBeacon)

        var verified = Set<String>()
        for address in beacons {
            let (reachable, busy) = await probe(host: address)
            merged[address] = ConsoleFound(
                address: address,
                busy: busy,
                source: reachable ? .beacon : .beaconUnverified
            )
            if reachable { verified.insert(address) }
        }

        progress?(
            beacons.isEmpty
                ? "No beacon heard — sweeping LAN as fallback…"
                : "Beacon heard from \(beacons.count) host(s) — sweeping to be sure…"
        )

        let swept = await sweep(
            networks: networks ?? localNetworks(),
            skipAddresses: verified,
            progress: progress
        )
        for found in swept where merged[found.address] == nil {
            merged[found.address] = found
        }
        return sorted(merged.values)
    }

    /// Listen for receiver UDP beacons for `duration` seconds.
    public func listenForBeacons(
        duration: TimeInterval,
        onBeacon: (@Sendable (String) -> Void)? = nil
    ) async -> [String] {
        await SocketSupport.runBlocking {
            Self.receiveBeacons(duration: duration, onBeacon: onBeacon)
        }
    }

    /// Sweep every (non-virtual) NIC subnet for the receiver ports.
    public func sweep(
        networks: [LanNetwork],
        skipAddresses: Set<String> = [],
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> [ConsoleFound] {
        let usable = networks.filter { !$0.isVirtual }
        let skipped = networks.filter { $0.isVirtual }
        if !skipped.isEmpty {
            progress?("Skipping virtual adapter(s): \(skipped.map(\.interfaceName).joined(separator: ", "))")
        }

        var collected: [IPv4Address] = []
        for network in usable {
            if network.isTruncated(maxHosts: Self.maxHostsPerNetwork) {
                progress?(
                    "Large subnet on \(network.interfaceName) (/\(network.prefixLength))"
                        + " — scanning first \(Self.maxHostsPerNetwork) hosts…"
                )
            }
            collected.append(
                contentsOf: network
                    .hosts(maxHosts: Self.maxHostsPerNetwork)
                    .filter { !skipAddresses.contains($0.description) }
            )
        }
        let targets = collected
        progress?("Scanning \(targets.count) addresses…")

        let open = await SocketSupport.runBlocking { Self.scanPorts(targets) }

        var results: [String: ConsoleFound] = [:]
        await withTaskGroup(of: (String, Bool, Bool?).self) { group in
            for (address, _) in open {
                group.addTask {
                    let (reachable, busy) = await self.probe(host: address)
                    return (address, reachable, busy)
                }
            }
            for await (address, reachable, busy) in group {
                results[address] = ConsoleFound(
                    address: address,
                    busy: busy,
                    source: reachable ? .sweep : .portOpen
                )
            }
        }
        return sorted(results.values)
    }

    /// `/api` probe plus `busy` flag of one console.
    public func probe(host: String) async -> (reachable: Bool, busy: Bool?) {
        guard await client.isOnline(host: host) else { return (false, nil) }
        guard let status = await client.status(host: host) else { return (true, nil) }
        return (true, status.supported ? status.busy : nil)
    }

    // MARK: - PC announce

    /// Broadcast this Mac's catalog endpoint until `stopAnnouncingPc()`.
    public func startAnnouncingPc(address: String, catalogPort: Int, interval: TimeInterval = 3) {
        stopAnnouncingPc()
        let message = "\(Self.pcAnnounceMagic) \(address):\(catalogPort)"
        let seconds = max(0.5, interval)
        announceTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                Self.sendAnnouncement(message)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    public func stopAnnouncingPc() {
        announceTask?.cancel()
        announceTask = nil
    }

    private static func sendAnnouncement(_ message: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var target = SocketSupport.sockaddrIn(.broadcastAll, port: pcAnnouncePort)
        let bytes = Array(message.utf8)
        _ = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bytes.withUnsafeBytes { raw in
                    sendto(fd, raw.baseAddress, bytes.count, 0, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Internals

    private static func receiveBeacons(
        duration: TimeInterval,
        onBeacon: (@Sendable (String) -> Void)?
    ) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        SocketSupport.setReuseAddress(fd)

        var bindAddress = SocketSupport.sockaddrIn(.zero, port: beaconPort)
        let bound = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return [] }

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var found: [String] = []
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline, !Task.isCancelled {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &storage) { pointer -> Int in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            guard read > 0 else { continue } // timeout (EAGAIN) or shutdown

            let text = String(decoding: buffer[0..<read], as: UTF8.self)
            guard text.hasPrefix(beaconMagic) else { continue }
            guard let sender = SocketSupport.senderAddress(of: storage), !sender.isLoopback else { continue }

            let address = sender.description
            if seen.insert(address).inserted {
                found.append(address)
                onBeacon?(address)
            }
        }
        return found
    }

    /// Blocking port scan (12800 then 9090) over every target address.
    private static func scanPorts(_ targets: [IPv4Address]) -> [(String, Int)] {
        let sink = PortScanSink()
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            if Task.isCancelled { return }
            let address = targets[index]
            if SocketSupport.canConnect(to: address, port: receiverPort, timeoutMs: 300) {
                sink.add((address.description, receiverPort))
                return
            }
            if SocketSupport.canConnect(to: address, port: fallbackReceiverPort, timeoutMs: 300) {
                sink.add((address.description, fallbackReceiverPort))
            }
        }
        return sink.snapshot
    }

    /// Lock-protected accumulator for the parallel port scan.
    private final class PortScanSink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Int)] = []

        func add(_ item: (String, Int)) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }

        var snapshot: [(String, Int)] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private func sorted(_ values: some Sequence<ConsoleFound>) -> [ConsoleFound] {
        values.sorted { lhs, rhs in
            let left = IPv4Address(lhs.address)?.rawValue ?? UInt32.max
            let right = IPv4Address(rhs.address)?.rawValue ?? UInt32.max
            return left < right
        }
    }
}
