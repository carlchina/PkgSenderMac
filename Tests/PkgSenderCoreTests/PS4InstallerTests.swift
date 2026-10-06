import XCTest
import Foundation
@testable import PkgSenderCore

/// GoldHEN manifest, payload patching and the callback struct.
final class PS4InstallerTests: XCTestCase {
    // MARK: - Manifest

    func testSinglePieceManifest() {
        let json = PS4Installer.buildManifest(
            url: "http://192.168.1.5:9898/json/abc.json",
            fileSize: 1000,
            digest: "deadbeef"
        )
        XCTAssertEqual(
            json,
            """
            {"originalFileSize":1000,"packageDigest":"deadbeef","numberOfSplitFiles":1,"pieces":\
            [{"url":"http://192.168.1.5:9898/json/abc.json","fileOffset":0,"fileSize":1000,\
            "hashValue":"0000000000000000000000000000000000000000"}]}
            """
        )
    }

    func testSplitPiecesCoverTheWholeFile() {
        let json = PS4Installer.buildManifest(
            urlForPiece: { "http://192.168.1.5:9898/pkg/abc.p\($0)" },
            fileSize: 1000,
            pieces: 4,
            digest: ""
        )
        XCTAssertTrue(json.contains("\"numberOfSplitFiles\":4"))
        XCTAssertTrue(json.contains("\"url\":\"http://192.168.1.5:9898/pkg/abc.p0\""))
        XCTAssertTrue(json.contains("\"fileOffset\":0,\"fileSize\":250"))
        XCTAssertTrue(json.contains("\"fileOffset\":250,\"fileSize\":250"))
        XCTAssertTrue(json.contains("\"fileOffset\":500,\"fileSize\":250"))
        XCTAssertTrue(json.contains("\"fileOffset\":750,\"fileSize\":250"))
    }

    func testUnevenSplitHasNoGap() {
        // 1001 bytes over 4 pieces: 250/250/250/251.
        let json = PS4Installer.buildManifest(urlForPiece: { _ in "u" }, fileSize: 1001, pieces: 4)
        XCTAssertTrue(json.contains("\"fileOffset\":0,\"fileSize\":250"))
        XCTAssertTrue(json.contains("\"fileOffset\":250,\"fileSize\":250"))
        XCTAssertTrue(json.contains("\"fileOffset\":500,\"fileSize\":250"))
        XCTAssertTrue(json.contains("\"fileOffset\":750,\"fileSize\":251"))
    }

    func testPieceCountIsClamped() {
        XCTAssertTrue(PS4Installer.buildManifest(urlForPiece: { _ in "u" }, fileSize: 100, pieces: 0)
            .contains("\"numberOfSplitFiles\":1"))
        XCTAssertTrue(PS4Installer.buildManifest(urlForPiece: { _ in "u" }, fileSize: 100, pieces: 99)
            .contains("\"numberOfSplitFiles\":16"))
    }

    func testSplitCountThresholds() {
        XCTAssertEqual(PS4Installer.splitCount(fileSize: 0), 1)
        XCTAssertEqual(PS4Installer.splitCount(fileSize: 255 << 20), 1)
        XCTAssertEqual(PS4Installer.splitCount(fileSize: 256 << 20), 2)
        XCTAssertEqual(PS4Installer.splitCount(fileSize: (1 << 30) - 1), 2)
        XCTAssertEqual(PS4Installer.splitCount(fileSize: 1 << 30), 4)
    }

    func testDigestAndQuotesAreEscaped() {
        let json = PS4Installer.buildManifest(url: "http://h/x", fileSize: 10, digest: "a\"b")
        XCTAssertTrue(json.contains(#""packageDigest":"a\"b""#), json)
        // Newlines would break the request: they become spaces.
        let withNewline = PS4Installer.buildManifest(url: "http://h/a\nb", fileSize: 10)
        XCTAssertTrue(withNewline.contains("http://h/a b"), withNewline)
    }

    // MARK: - Payload patch

    func testPatchesMarkerWithAddressAndPort() throws {
        var payload = Data([0x01, 0x02])
        payload.append(contentsOf: PS4Installer.payloadMarker)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])

        let patched = try PS4Installer.patchedPayload(payload, pcAddress: "192.168.1.7", callbackPort: 41234)
        let bytes = [UInt8](patched)
        XCTAssertEqual(bytes.count, payload.count)
        XCTAssertEqual(Array(bytes[0..<2]), [0x01, 0x02])
        XCTAssertEqual(Array(bytes[2..<6]), [192, 168, 1, 7])
        XCTAssertEqual(Array(bytes[6..<8]), [0xA1, 0x12]) // 41234 = 0xA112, big-endian
        XCTAssertEqual(Array(bytes[8..<14]), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(bytes[14], 0x03) // untouched payload tail
    }

    func testMarkerSearch() {
        let data = Data([0xAA, 0xB4, 0xB4, 0xB4, 0xB4, 0xB4, 0xB4, 0xBB])
        XCTAssertEqual(PS4Installer.index(of: PS4Installer.payloadMarker, in: data), 1)
        XCTAssertNil(PS4Installer.index(of: PS4Installer.payloadMarker, in: Data([0xB4, 0xB4])))
    }

    func testPatchErrors() {
        XCTAssertThrowsError(try PS4Installer.patchedPayload(Data(), pcAddress: "1.2.3.4", callbackPort: 1)) { error in
            guard case .missingPayload = error as? PS4InstallerError else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertThrowsError(
            try PS4Installer.patchedPayload(Data([0x01, 0x02]), pcAddress: "1.2.3.4", callbackPort: 1)
        ) { error in
            guard case .markerNotFound = error as? PS4InstallerError else {
                return XCTFail("unexpected \(error)")
            }
        }
        var short = Data(PS4Installer.payloadMarker)
        short.append(0x01)
        XCTAssertThrowsError(try PS4Installer.patchedPayload(short, pcAddress: "1.2.3.4", callbackPort: 1)) { error in
            guard case .payloadTooShort = error as? PS4InstallerError else {
                return XCTFail("unexpected \(error)")
            }
        }
        var payload = Data(PS4Installer.payloadMarker)
        payload.append(contentsOf: [0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try PS4Installer.patchedPayload(payload, pcAddress: "not-an-ip", callbackPort: 1)) { error in
            guard case .invalidAddress = error as? PS4InstallerError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    // MARK: - Callback struct

    func testContentTypeNormalization() {
        XCTAssertEqual(PS4Installer.normalizedContentType("gd"), "PS4GD")
        XCTAssertEqual(PS4Installer.normalizedContentType("ac"), "PS4AC")
        XCTAssertEqual(PS4Installer.normalizedContentType(""), "PS4GD")
        XCTAssertEqual(PS4Installer.normalizedContentType("PS4GD"), "PS4GD")
        XCTAssertEqual(PS4Installer.normalizedContentType(" ps4dl "), "PS4DL")
    }

    func testCallbackPayloadLayout() {
        let descriptor = PS4PackageDescriptor(
            url: "http://192.168.1.5:9898/json/abc.json",
            size: 0x1234,
            digest: "",
            title: "Game",
            titleId: "CUSA00001",
            contentId: "EP0001-CUSA00001_00-ABCDE",
            contentType: "gd",
            iconData: nil
        )
        let bytes = [UInt8](PS4Installer.callbackPayload(descriptor: descriptor, url: descriptor.url))
        var offset = 0
        func u32() -> UInt32 {
            var value: UInt32 = 0
            for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
            offset += 4
            return value
        }
        func blob() -> String {
            let length = Int(u32())
            let value = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            offset += length
            return value
        }

        XCTAssertEqual(u32(), 1) // new package
        XCTAssertEqual(blob(), descriptor.url)
        XCTAssertEqual(blob(), "Game")
        XCTAssertEqual(blob(), descriptor.contentId)
        XCTAssertEqual(blob(), "PS4GD")
        var size: UInt64 = 0
        for index in 0..<8 { size |= UInt64(bytes[offset + index]) << (8 * index) }
        offset += 8
        XCTAssertEqual(size, 0x1234)
        XCTAssertEqual(u32(), 0) // no icon
        XCTAssertEqual(offset, bytes.count)
    }

    func testCallbackPayloadFallsBackToTitleIdAndCarriesIcon() {
        var descriptor = PS4PackageDescriptor(
            url: "http://h/pkg",
            size: 1,
            title: "  ",
            titleId: "CUSA00002",
            contentId: "",
            contentType: "gd",
            iconData: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let bytes = [UInt8](PS4Installer.callbackPayload(descriptor: descriptor, url: descriptor.url))
        XCTAssertTrue(contains(bytes, Array("CUSA00002".utf8)))
        XCTAssertTrue(contains(bytes, Array("PS4GD".utf8)))
        XCTAssertEqual(Array(bytes.suffix(4)), [0x89, 0x50, 0x4E, 0x47])

        descriptor.iconData = nil
        let withoutIcon = [UInt8](PS4Installer.callbackPayload(descriptor: descriptor, url: descriptor.url))
        XCTAssertEqual(Array(withoutIcon.suffix(4)), [0, 0, 0, 0])
    }

    /// `contains(other:)` on collections is macOS 13+, so search by hand.
    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}
