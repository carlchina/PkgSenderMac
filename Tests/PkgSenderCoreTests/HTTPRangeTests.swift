import XCTest
import Foundation
@testable import PkgSenderCore

/// `Range` header parsing: 200 / 206 / 416 decisions of the local server.
final class HTTPRangeTests: XCTestCase {
    func testNoRangeAnswersFull() {
        let range = HTTPRangeParser.parse(header: nil, size: 1000)
        XCTAssertEqual(range, .full(size: 1000))
        XCTAssertEqual(range.statusCode, 200)
        XCTAssertEqual(range.length, 1000)
        XCTAssertNil(range.contentRange)
    }

    func testNonByteUnitIsIgnored() {
        XCTAssertEqual(HTTPRangeParser.parse(header: "items=0-10", size: 1000), .full(size: 1000))
    }

    func testClosedRange() {
        let range = HTTPRangeParser.parse(header: "bytes=10-19", size: 1000)
        XCTAssertEqual(range, .partial(start: 10, end: 19, size: 1000))
        XCTAssertEqual(range.statusCode, 206)
        XCTAssertEqual(range.length, 10)
        XCTAssertEqual(range.contentRange, "bytes 10-19/1000")
    }

    func testOpenEndedRangeRunsToEnd() {
        let range = HTTPRangeParser.parse(header: "bytes=990-", size: 1000)
        XCTAssertEqual(range, .partial(start: 990, end: 999, size: 1000))
        XCTAssertEqual(range.length, 10)
    }

    func testSuffixRange() {
        let range = HTTPRangeParser.parse(header: "bytes=-10", size: 1000)
        XCTAssertEqual(range, .partial(start: 990, end: 999, size: 1000))
    }

    func testSuffixRangeLargerThanFileClampsToZero() {
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=-5000", size: 1000), .partial(start: 0, end: 999, size: 1000))
    }

    func testEndBeyondSizeIsClamped() {
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=995-5000", size: 1000), .partial(start: 995, end: 999, size: 1000))
    }

    func testStartPastEndIsUnsatisfiable() {
        let range = HTTPRangeParser.parse(header: "bytes=1000-", size: 1000)
        XCTAssertEqual(range, .unsatisfiable(size: 1000))
        XCTAssertEqual(range.statusCode, 416)
        XCTAssertEqual(range.contentRange, "bytes */1000")
        XCTAssertEqual(range.length, 0)
    }

    func testReversedRangeIsUnsatisfiable() {
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=20-10", size: 1000), .unsatisfiable(size: 1000))
    }

    func testMultiRangeFallsBackToFull() {
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=0-9,20-29", size: 1000), .full(size: 1000))
    }

    func testGarbageFallsBackToFull() {
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=abc", size: 1000), .full(size: 1000))
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=", size: 1000), .full(size: 1000))
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=1-2-3", size: 1000), .full(size: 1000))
    }

    func testEmptyFile() {
        XCTAssertEqual(HTTPRangeParser.parse(header: nil, size: 0), .full(size: 0))
        XCTAssertEqual(HTTPRangeParser.parse(header: "bytes=0-", size: 0), .unsatisfiable(size: 0))
    }

    func testMultipleHeadersLastValidWins() {
        let range = HTTPRangeParser.parse(headers: ["bytes=0-9", "bytes=100-199"], size: 1000)
        XCTAssertEqual(range, .partial(start: 100, end: 199, size: 1000))
    }

    func testUnsatisfiableShortCircuits() {
        let range = HTTPRangeParser.parse(headers: ["bytes=0-9", "bytes=9000-", "bytes=5-6"], size: 1000)
        XCTAssertEqual(range, .unsatisfiable(size: 1000))
    }

    func testRequestHeadParsing() {
        let raw = "GET /pkg/abc?product=1 HTTP/1.1\r\nHost: 192.168.1.5:9898\r\nRange: bytes=0-9\r\nConnection: keep-alive\r\n\r\n"
        let head = HTTPRequestHead.parse(raw)
        XCTAssertNotNil(head)
        XCTAssertEqual(head?.method, "GET")
        XCTAssertEqual(head?.path, "/pkg/abc")
        XCTAssertEqual(head?.query, "product=1")
        XCTAssertEqual(head?.values(for: "range"), ["bytes=0-9"])
        XCTAssertEqual(head?.value(for: "HOST"), "192.168.1.5:9898")
        XCTAssertTrue(head?.wantsKeepAlive == true)
    }

    func testKeepAliveDefaults() {
        let http11 = HTTPRequestHead.parse("GET /pkg HTTP/1.1\r\n\r\n")
        XCTAssertTrue(http11?.wantsKeepAlive == true)

        let close = HTTPRequestHead.parse("GET /pkg HTTP/1.1\r\nConnection: close\r\n\r\n")
        XCTAssertFalse(close?.wantsKeepAlive == true)

        let http10 = HTTPRequestHead.parse("GET /pkg HTTP/1.0\r\n\r\n")
        XCTAssertFalse(http10?.wantsKeepAlive == true)

        let keep10 = HTTPRequestHead.parse("GET /pkg HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n")
        XCTAssertTrue(keep10?.wantsKeepAlive == true)
    }
}
