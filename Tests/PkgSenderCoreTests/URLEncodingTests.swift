import XCTest
import Foundation
@testable import PkgSenderCore

/// URL encoding: the receiver decodes once, so we must encode exactly once.
final class URLEncodingTests: XCTestCase {
    func testEncodesReservedCharacters() {
        XCTAssertEqual(URLEncoding.encode("http://1.2.3.4:9898/pkg/a b.pkg"), "http%3A%2F%2F1.2.3.4%3A9898%2Fpkg%2Fa%20b.pkg")
    }

    func testUnreservedCharactersSurvive() {
        XCTAssertEqual(URLEncoding.encode("AZaz09-._~"), "AZaz09-._~")
    }

    func testEncodeOnceIsIdempotent() {
        let raw = "http://1.2.3.4:9898/pkg/Game of Thrones.pkg"
        let once = URLEncoding.encodeOnce(raw)
        XCTAssertEqual(once, URLEncoding.encode(raw))
        // Encoding the already-encoded URL must not double-escape %20.
        XCTAssertEqual(URLEncoding.encodeOnce(once), once)
        XCTAssertFalse(once.contains("%25"))
    }

    func testDecodeRoundTrip() {
        let raw = "http://1.2.3.4:9898/pkg/a b+c&d.pkg"
        XCTAssertEqual(URLEncoding.decode(URLEncoding.encode(raw)), raw)
    }

    func testPathComponentAndQueryValue() {
        XCTAssertEqual(URLEncoding.encodePathComponent("my pkg"), "my%20pkg")
        XCTAssertEqual(URLEncoding.encodeQueryValue("/data/homebrew/a b.pkg"), "%2Fdata%2Fhomebrew%2Fa%20b.pkg")
    }

    func testServerURLsEncodeIdentifiersOnce() {
        let server = RangeHTTPServer(files: ["pkg": "/tmp/x.pkg"], port: 9898)
        XCTAssertEqual(server.url(host: "192.168.1.5"), "http://192.168.1.5:9898/pkg")
        XCTAssertEqual(server.url(host: "192.168.1.5", id: "my pkg"), "http://192.168.1.5:9898/pkg/my%20pkg")
        XCTAssertEqual(server.iconURL(host: "192.168.1.5", id: "my pkg"), "http://192.168.1.5:9898/icon/my%20pkg")
        XCTAssertEqual(server.manifestURL(host: "192.168.1.5", id: "abc"), "http://192.168.1.5:9898/json/abc.json")
        XCTAssertEqual(server.catalogURL(host: "192.168.1.5"), "http://192.168.1.5:9898/catalog")
        // An already-encoded id must not be encoded twice.
        XCTAssertEqual(server.url(host: "h", id: "my%20pkg"), "http://h:9898/pkg/my%20pkg")
    }

    func testConsoleEndpoints() {
        let client = ConsoleClient()
        XCTAssertEqual(client.endpoint(host: "192.168.1.9", port: 12800, path: "/api"), "http://192.168.1.9:12800/api")
        XCTAssertEqual(
            client.endpoint(host: "fe80::1", port: 9090, path: "/status"),
            "http://[fe80::1]:9090/status"
        )
    }

    func testStatPathIsEncoded() {
        // Mirrors ConsoleClient.stat: the remote path travels percent-encoded.
        let path = "/data/homebrew/My Game.pkg"
        XCTAssertEqual(
            "/api/files/stat?path=" + URLEncoding.encodeQueryValue(path),
            "/api/files/stat?path=%2Fdata%2Fhomebrew%2FMy%20Game.pkg"
        )
    }
}
