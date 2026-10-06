import XCTest
import Foundation
@testable import PkgSenderCore

/// Subnet maths and interface enumeration: never assume a /24.
final class LanNetworkTests: XCTestCase {
    // MARK: - IPv4Address

    func testAddressRoundTrip() {
        let address = IPv4Address(rawValue: 0xC0A8_0107)
        XCTAssertEqual(address.description, "192.168.1.7")
        XCTAssertEqual(address.octets, [192, 168, 1, 7])
        XCTAssertEqual(IPv4Address("192.168.1.7"), address)
    }

    func testAddressParsingRejectsGarbage() {
        XCTAssertNil(IPv4Address("192.168.1"))
        XCTAssertNil(IPv4Address("192.168.1.256"))
        XCTAssertNil(IPv4Address("192.168.1.7.9"))
        XCTAssertNil(IPv4Address(""))
        XCTAssertNil(IPv4Address("abc"))
    }

    func testLoopbackAndLinkLocal() {
        XCTAssertTrue(IPv4Address("127.0.0.1")?.isLoopback == true)
        XCTAssertFalse(IPv4Address("192.168.1.1")?.isLoopback == true)
        XCTAssertTrue(IPv4Address("169.254.3.4")?.isLinkLocal == true)
        XCTAssertFalse(IPv4Address("168.254.3.4")?.isLinkLocal == true)
    }

    // MARK: - Subnets

    func testTypical24() {
        let network = LanNetwork(
            interfaceName: "en0",
            interfaceDescription: "en0",
            address: IPv4Address("192.168.1.7")!,
            mask: IPv4Address("255.255.255.0")!
        )
        XCTAssertEqual(network.prefixLength, 24)
        XCTAssertEqual(network.network.description, "192.168.1.0")
        XCTAssertEqual(network.broadcast.description, "192.168.1.255")
        XCTAssertTrue(network.contains(IPv4Address("192.168.1.200")!))
        XCTAssertFalse(network.contains(IPv4Address("192.168.2.1")!))

        let hosts = network.hosts()
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first?.description, "192.168.1.1")
        XCTAssertEqual(hosts.last?.description, "192.168.1.254")
        XCTAssertFalse(network.isTruncated())
    }

    func testSixteenBitSubnetIsTruncated() {
        let network = LanNetwork(
            interfaceName: "en1",
            interfaceDescription: "en1",
            address: IPv4Address("172.16.5.9")!,
            mask: IPv4Address("255.255.0.0")!
        )
        XCTAssertEqual(network.prefixLength, 16)
        XCTAssertEqual(network.network.description, "172.16.0.0")
        XCTAssertEqual(network.broadcast.description, "172.16.255.255")
        XCTAssertTrue(network.isTruncated())
        XCTAssertEqual(network.hosts().count, LanNetwork.defaultMaxHosts)
        XCTAssertFalse(network.isTruncated(maxHosts: 1_000_000))
    }

    func testOddMaskIsNotAssumed() {
        // 255.255.255.224 → /27, 30 usable hosts.
        let network = LanNetwork(
            interfaceName: "en0",
            interfaceDescription: "en0",
            address: IPv4Address("10.0.0.44")!,
            mask: IPv4Address("255.255.255.224")!
        )
        XCTAssertEqual(network.prefixLength, 27)
        XCTAssertEqual(network.network.description, "10.0.0.32")
        XCTAssertEqual(network.broadcast.description, "10.0.0.63")
        let hosts = network.hosts()
        XCTAssertEqual(hosts.count, 30)
        XCTAssertEqual(hosts.first?.description, "10.0.0.33")
        XCTAssertEqual(hosts.last?.description, "10.0.0.62")
    }

    func testSlash30() {
        let network = LanNetwork(
            interfaceName: "en0",
            interfaceDescription: "en0",
            address: IPv4Address("10.0.0.1")!,
            mask: IPv4Address("255.255.255.252")!
        )
        XCTAssertEqual(network.prefixLength, 30)
        XCTAssertEqual(network.hosts().map(\.description), ["10.0.0.1", "10.0.0.2"])
    }

    func testSlash31KeepsBothAddresses() {
        let network = LanNetwork(
            interfaceName: "en0",
            interfaceDescription: "en0",
            address: IPv4Address("10.0.0.0")!,
            mask: IPv4Address("255.255.255.254")!
        )
        XCTAssertEqual(network.prefixLength, 31)
        XCTAssertEqual(network.hosts().map(\.description), ["10.0.0.0", "10.0.0.1"])
        XCTAssertFalse(network.isTruncated())
    }

    func testSlash32() {
        let network = LanNetwork(
            interfaceName: "utun3",
            interfaceDescription: "utun3",
            address: IPv4Address("10.7.0.3")!,
            mask: IPv4Address("255.255.255.255")!
        )
        XCTAssertEqual(network.prefixLength, 32)
        XCTAssertEqual(network.hosts().map(\.description), ["10.7.0.3"])
    }

    func testMaxHostsCap() {
        let network = LanNetwork(
            interfaceName: "en0",
            interfaceDescription: "en0",
            address: IPv4Address("192.168.1.7")!,
            mask: IPv4Address("255.255.255.0")!
        )
        XCTAssertEqual(network.hosts(maxHosts: 10).count, 10)
        XCTAssertTrue(network.isTruncated(maxHosts: 10))
    }

    // MARK: - Interface enumeration

    func testLocalNetworksExcludeLoopbackAndLinkLocal() {
        for network in LanNetwork.localNetworks(includeVirtual: true) {
            XCTAssertNotEqual(network.interfaceName, "lo0")
            XCTAssertFalse(network.address.isLoopback, "\(network)")
            XCTAssertFalse(network.address.isLinkLocal, "\(network)")
            XCTAssertNotEqual(network.mask.rawValue, 0, "\(network)")
            XCTAssertTrue(network.contains(network.address), "\(network)")
        }
    }

    func testVirtualAdaptersAreHiddenByDefault() {
        let all = LanNetwork.localNetworks(includeVirtual: true)
        let usable = LanNetwork.localNetworks()
        XCTAssertLessThanOrEqual(usable.count, all.count)
        for network in usable {
            XCTAssertFalse(network.isVirtual, "\(network)")
        }
    }

    func testVirtualDetection() {
        XCTAssertTrue(LanNetwork.isVirtualInterface(name: "utun4", description: "utun4"))
        XCTAssertTrue(LanNetwork.isVirtualInterface(name: "awdl0", description: "awdl0"))
        XCTAssertTrue(LanNetwork.isVirtualInterface(name: "bridge0", description: "bridge0"))
        XCTAssertTrue(LanNetwork.isVirtualInterface(name: "vmnet1", description: "vmnet1"))
        XCTAssertTrue(LanNetwork.isVirtualInterface(name: "llw0", description: "llw0"))
        XCTAssertTrue(LanNetwork.isVirtualInterface(name: "en0", description: "Tailscale tunnel"))
        XCTAssertFalse(LanNetwork.isVirtualInterface(name: "en0", description: "Ethernet"))
        XCTAssertFalse(LanNetwork.isVirtualInterface(name: "en1", description: "Wi-Fi"))
    }

    func testBestLocalAddressPrefersSameSubnet() {
        let networks = [
            LanNetwork(
                interfaceName: "en0",
                interfaceDescription: "en0",
                address: IPv4Address("192.168.1.7")!,
                mask: IPv4Address("255.255.255.0")!
            ),
            LanNetwork(
                interfaceName: "en1",
                interfaceDescription: "en1",
                address: IPv4Address("10.0.0.5")!,
                mask: IPv4Address("255.255.255.0")!
            ),
        ]
        XCTAssertEqual(LanNetwork.bestLocalAddress(networks, consoleAddress: "10.0.0.42")?.description, "10.0.0.5")
        XCTAssertEqual(LanNetwork.bestLocalAddress(networks, consoleAddress: "192.168.1.50")?.description, "192.168.1.7")
        XCTAssertEqual(LanNetwork.bestLocalAddress(networks, consoleAddress: nil)?.description, "192.168.1.7")
        XCTAssertNil(LanNetwork.bestLocalAddress([], consoleAddress: "10.0.0.42"))
    }
}
