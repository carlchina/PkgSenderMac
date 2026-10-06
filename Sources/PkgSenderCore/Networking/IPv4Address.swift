import Darwin
import Foundation

/// A 32-bit IPv4 address in host byte order.
///
/// Carries the raw value so subnet maths (network/broadcast/host ranges) is
/// plain integer arithmetic instead of string juggling.
public struct IPv4Address: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        rawValue = (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    public init?(_ text: String) {
        let parts = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            result = (result << 8) | UInt32(octet)
        }
        rawValue = result
    }

    /// Octets in network order (a.b.c.d).
    public var octets: [UInt8] {
        [
            UInt8(truncatingIfNeeded: rawValue >> 24),
            UInt8(truncatingIfNeeded: rawValue >> 16),
            UInt8(truncatingIfNeeded: rawValue >> 8),
            UInt8(truncatingIfNeeded: rawValue),
        ]
    }

    public var description: String {
        octets.map(String.init).joined(separator: ".")
    }

    /// Address bytes as they appear on the wire (network byte order).
    public var bigEndianRawValue: UInt32 { rawValue.bigEndian }

    public static let zero = IPv4Address(rawValue: 0)
    public static let broadcastAll = IPv4Address(rawValue: 0xFFFF_FFFF)

    public func applying(mask: IPv4Address) -> IPv4Address {
        IPv4Address(rawValue: rawValue & mask.rawValue)
    }

    public func broadcastAddress(mask: IPv4Address) -> IPv4Address {
        IPv4Address(rawValue: rawValue | ~mask.rawValue)
    }

    public var isLoopback: Bool { (rawValue >> 24) == 127 }

    /// 169.254.0.0/16 — APIPA, no router, practically never a console.
    public var isLinkLocal: Bool { (rawValue >> 16) == 0xA9FE }
}

/// One active IPv4 NIC with its **real** netmask.
///
/// Network address, broadcast address, prefix length and the usable host range
/// are all derived from address+mask bytes — never from an assumed /24.
public struct LanNetwork: Sendable, Hashable, CustomStringConvertible {
    /// Upper bound on hosts enumerated per NIC, so a huge subnet cannot turn a
    /// sweep into a denial of service.
    public static let defaultMaxHosts = 4096

    public let interfaceName: String
    public let interfaceDescription: String
    public let address: IPv4Address
    public let mask: IPv4Address
    public let network: IPv4Address
    public let broadcast: IPv4Address
    public let prefixLength: Int

    public init(interfaceName: String, interfaceDescription: String, address: IPv4Address, mask: IPv4Address) {
        self.interfaceName = interfaceName
        self.interfaceDescription = interfaceDescription
        self.address = address
        self.mask = mask
        network = address.applying(mask: mask)
        broadcast = address.broadcastAddress(mask: mask)
        var bits = 0
        var rest = mask.rawValue
        while rest != 0 {
            bits += Int(rest & 1)
            rest >>= 1
        }
        prefixLength = bits
    }

    public var description: String {
        "\(interfaceName) \(address.description)/\(prefixLength) network=\(network.description)"
    }

    /// True when `ip` falls inside this subnet.
    public func contains(_ ip: IPv4Address) -> Bool {
        ip.applying(mask: mask) == network
    }

    /// Usable host addresses: network and broadcast excluded, except for
    /// /31 and /32 where every address is usable.
    public func hosts(maxHosts: Int = defaultMaxHosts) -> [IPv4Address] {
        if prefixLength >= 31 {
            var result = [network]
            if broadcast != network { result.append(broadcast) }
            return result
        }
        let first = UInt64(network.rawValue)
        let last = UInt64(broadcast.rawValue)
        var result: [IPv4Address] = []
        result.reserveCapacity(Int(min(UInt64(maxHosts), last - first)))
        var host = first + 1
        while host < last, result.count < maxHosts {
            result.append(IPv4Address(rawValue: UInt32(truncatingIfNeeded: host)))
            host += 1
        }
        return result
    }

    /// True when `hosts(maxHosts:)` had to stop early.
    public func isTruncated(maxHosts: Int = defaultMaxHosts) -> Bool {
        guard prefixLength < 31 else { return false }
        let total = UInt64(broadcast.rawValue) - UInt64(network.rawValue) - 1
        return total > UInt64(maxHosts)
    }

    /// Virtual switches (VPN, VM, AWDL, tunnels…) never carry a console.
    ///
    /// Still reported by `localNetworks(includeVirtual:)` so the user can pick
    /// a PC address from them; skipped by sweeps.
    public var isVirtual: Bool {
        LanNetwork.isVirtualInterface(name: interfaceName, description: interfaceDescription)
    }

    public static func isVirtualInterface(name: String, description: String) -> Bool {
        let haystack = (name + " " + description).lowercased()
        return virtualMarkers.contains { haystack.contains($0) }
    }

    /// Markers of virtual/tunnel adapters — the upstream Windows names plus
    /// the macOS equivalents (`utun*`, `awdl0`, `llw0`, `bridge0`, `vmnet*`…).
    public static let virtualMarkers: [String] = [
        "virtual", "hyper-v", "hyperv", "wsl", "vmware", "virtualbox", "vbox",
        "vpn", "pseudo", "wireguard", "tailscale", "tap-", "tun", "tap",
        "bridge", "awdl", "llw", "utun", "vmnet", "vmenet", "anpi",
        "gif", "stf", "pktap", "vlan", "ppp", "ipseca", "ipsec", "wg",
        "ap1", "lo0", "docker", "zerotier", "nebula",
    ]
}

// MARK: - Interfaces

public extension LanNetwork {
    /// Every active IPv4 interface with a real netmask, via `getifaddrs`.
    ///
    /// Excludes loopback (`lo0` / 127.0.0.0/8) and link-local 169.254.0.0/16
    /// (no router: a console is practically never reachable there).
    /// - Parameter includeVirtual: when true, VPN/VM/tunnel adapters are
    ///   listed too (useful for choosing the PC address).
    static func localNetworks(includeVirtual: Bool = false) -> [LanNetwork] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var result: [LanNetwork] = []
        var seen = Set<String>()
        var cursor = head
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let info = entry.pointee
            let name = String(cString: info.ifa_name)
            guard let addr = info.ifa_addr, let mask = info.ifa_netmask else { continue }
            guard Int32(addr.pointee.sa_family) == AF_INET,
                  Int32(mask.pointee.sa_family) == AF_INET else { continue }

            let flags = Int32(info.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard name != "lo0" else { continue }

            let address = IPv4Address(rawValue: UInt32(bigEndian: sockaddrIn(addr).sin_addr.s_addr))
            let netmask = IPv4Address(rawValue: UInt32(bigEndian: sockaddrIn(mask).sin_addr.s_addr))
            guard !address.isLoopback, !address.isLinkLocal, netmask.rawValue != 0 else { continue }

            let network = LanNetwork(
                interfaceName: name,
                interfaceDescription: name,
                address: address,
                mask: netmask
            )
            let key = "\(name)|\(address.description)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            if includeVirtual || !network.isVirtual {
                result.append(network)
            }
        }
        return result.sorted { $0.interfaceName < $1.interfaceName }
    }

    /// The PC address on the same subnet as the console (first match wins).
    static func bestLocalAddress(_ networks: [LanNetwork], consoleAddress: String?) -> IPv4Address? {
        guard !networks.isEmpty else { return nil }
        if let text = consoleAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let console = IPv4Address(text) {
            if let same = networks.first(where: { $0.contains(console) }) {
                return same.address
            }
        }
        return networks.first(where: { !$0.isVirtual })?.address ?? networks[0].address
    }

    private static func sockaddrIn(_ ptr: UnsafePointer<sockaddr>) -> sockaddr_in {
        ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }
}
