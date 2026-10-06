import XCTest
import Foundation
@testable import PkgSenderCore

/// Request bodies and JSON field parsing of the console client — no console
/// needed, everything here is pure string work.
final class ConsoleClientTests: XCTestCase {
    func testInstallRequestEncodesURLOnce() {
        let json = ConsoleClient.installRequest(url: "http://192.168.1.5:9898/pkg/My Game.pkg")
        XCTAssertEqual(
            json,
            "{\"type\":\"direct\",\"packages\":[\"http%3A%2F%2F192.168.1.5%3A9898%2Fpkg%2FMy%20Game.pkg\"]}"
        )
    }

    func testInstallRequestWithNameAndIcon() {
        let json = ConsoleClient.installRequest(
            url: "http://192.168.1.5:9898/pkg/a.pkg",
            name: "My \"Game\"",
            iconURL: "http://192.168.1.5:9898/icon/a b.png"
        )
        XCTAssertTrue(json.hasPrefix("{\"type\":\"direct\",\"packages\":["), json)
        XCTAssertTrue(json.hasSuffix("}"))
        XCTAssertTrue(json.contains("\"name\":\"My \\\"Game\\\"\""), json)
        XCTAssertTrue(
            json.contains("\"icon_url\":\"http%3A%2F%2F192.168.1.5%3A9898%2Ficon%2Fa%20b.png\""),
            json
        )
    }

    func testHTTPSIsDowngradedToHTTP() {
        let json = ConsoleClient.installRequest(url: "https://192.168.1.5:9898/pkg/a.pkg")
        XCTAssertFalse(json.contains("https%3A"), json)
        XCTAssertTrue(json.contains("http%3A"), json)
    }

    func testIconURLIsEncodedExactlyOnce() {
        let raw = ConsoleClient.installRequest(url: "http://h/pkg", iconURL: "http://h/icon/a b.png")
        let encoded = ConsoleClient.installRequest(url: "http://h/pkg", iconURL: "http://h/icon/a%20b.png")
        XCTAssertFalse(raw.contains("%25"), raw)
        XCTAssertFalse(encoded.contains("%25"), encoded)
        XCTAssertEqual(raw, encoded)
    }

    func testPullRequest() {
        XCTAssertEqual(
            ConsoleClient.pullRequest(url: "http://h/pkg/a", remotePath: "/data/homebrew/a.pkg", resume: false),
            "{\"url\":\"http://h/pkg/a\",\"path\":\"/data/homebrew/a.pkg\",\"mode\":\"overwrite\"}"
        )
        XCTAssertEqual(
            ConsoleClient.pullRequest(url: "http://h/pkg/a", remotePath: "/data/a.pkg", resume: true),
            "{\"url\":\"http://h/pkg/a\",\"path\":\"/data/a.pkg\",\"mode\":\"resume\"}"
        )
    }

    func testPauseRequest() {
        XCTAssertEqual(ConsoleClient.pauseRequest(paused: true), "{\"paused\":1}")
        XCTAssertEqual(ConsoleClient.pauseRequest(paused: false), "{\"paused\":0}")
    }

    func testPorts() {
        let client = ConsoleClient()
        XCTAssertEqual(client.ports, [12800, 9090])
        XCTAssertEqual(ConsoleClient.primaryPort, 12800)
        XCTAssertEqual(ConsoleClient.fallbackPort, 9090)
    }

    // MARK: - Response parsing

    func testStatusParsing() {
        XCTAssertTrue(JSONScalarReader.bool("{\"busy\":true,\"active\":1}", key: "busy"))
        XCTAssertFalse(JSONScalarReader.bool("{\"busy\": false}", key: "busy"))
        XCTAssertFalse(JSONScalarReader.bool("<html>WebUI</html>", key: "busy"))
    }

    func testPullProgressParsing() {
        let body = "{\"pull\":true,\"pullName\":\"a.pkg\",\"pullGot\":123,\"pullWant\":456,\"pullPaused\":true}"
        XCTAssertEqual(JSONScalarReader.string(body, key: "pullName"), "a.pkg")
        XCTAssertEqual(JSONScalarReader.integer(body, key: "pullGot"), 123)
        XCTAssertEqual(JSONScalarReader.integer(body, key: "pullWant"), 456)
        XCTAssertTrue(JSONScalarReader.bool(body, key: "pullPaused"))
        XCTAssertTrue(JSONScalarReader.bool(body, key: "pull"))
    }

    func testMissingFieldsFallBack() {
        XCTAssertEqual(JSONScalarReader.string("{}", key: "pullName"), "")
        XCTAssertNil(JSONScalarReader.integer("{}", key: "size"))
        XCTAssertNil(JSONScalarReader.integer("{\"size\":\"x\"}", key: "size"))
        XCTAssertEqual(JSONScalarReader.integer("{\"size\":-1}", key: "size"), -1)
    }

    func testStatParsing() {
        let body = "{\"exists\":true,\"size\":987654321}"
        XCTAssertTrue(JSONScalarReader.bool(body, key: "exists"))
        XCTAssertEqual(JSONScalarReader.integer(body, key: "size"), 987_654_321)
    }

    func testJSONEscaping() {
        XCTAssertEqual(JSONText.escape("a\"b\\c"), "a\\\"b\\\\c")
        XCTAssertEqual(JSONText.escape("a\u{01}b"), "a\\u0001b")
        XCTAssertEqual(JSONText.escapeForConsole("a\r\nb"), "a  b")
    }
}
