import XCTest
import Foundation
@testable import PkgSenderCore

/// End-to-end tests of the local range server over a real loopback socket.
final class RangeHTTPServerTests: XCTestCase {
    private var tempFiles: [String] = []

    override func tearDownWithError() throws {
        for path in tempFiles { try? FileManager.default.removeItem(atPath: path) }
        tempFiles = []
        try super.tearDownWithError()
    }

    private func fixture(_ size: Int = 1000) -> (path: String, data: Data) {
        var bytes = Data(count: size)
        for index in 0..<size { bytes[index] = UInt8(index % 251) }
        let path = TestSupport.tempFile(contents: bytes)
        tempFiles.append(path)
        return (path, bytes)
    }

    private func startServer(files: [String: String]) throws -> (RangeHTTPServer, Int) {
        let port = TestSupport.freePort()
        let server = RangeHTTPServer(files: files, port: port)
        try server.start()
        XCTAssertTrue(TestSupport.waitForServer(port: port), "server did not start on \(port)")
        return (server, port)
    }

    private func get(_ id: String = "pkg", _ range: String? = nil, port: Int) -> (head: String, body: Data)? {
        var request = "GET /pkg"
        if id != "pkg" { request += "/" + URLEncoding.encodeOnce(id) }
        request += " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let range { request += "Range: \(range)\r\n" }
        request += "Connection: close\r\n\r\n"
        return TestSupport.exchange(port: port, request)
    }

    // MARK: - Basic serving

    func testServesWholeFile() throws {
        let (path, data) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get(port: port))
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(TestSupport.header("Content-Length", in: response.head), "1000")
        XCTAssertEqual(TestSupport.header("Accept-Ranges", in: response.head), "bytes")
        XCTAssertEqual(response.body, data)
    }

    func testHeadReturnsHeadersOnly() throws {
        let (path, _) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "HEAD /pkg HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(TestSupport.header("Content-Length", in: response.head), "1000")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testMethodNotAllowed() throws {
        let (path, _) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "POST /pkg HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 405)
    }

    func testUnknownPathIs404() throws {
        let (path, _) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /nope HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 404)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "not found")
    }

    func testQueryStringIsIgnored() throws {
        let (path, data) = fixture(100)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        // Sony appends ?product=…; the id must still resolve.
        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /pkg?product=1 HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(response.body, data)
    }

    func testEncodedIdentifier() throws {
        let (path, data) = fixture(64)
        let (server, port) = try startServer(files: ["my pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get("my pkg", port: port))
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(response.body, data)
    }

    func testSeveralIdentifiers() throws {
        let first = fixture(10)
        let second = fixture(20)
        let (server, port) = try startServer(files: ["a": first.path, "b": second.path])
        defer { server.stop() }

        XCTAssertEqual(try XCTUnwrap(get("a", port: port)).body, first.data)
        XCTAssertEqual(try XCTUnwrap(get("b", port: port)).body, second.data)
        XCTAssertEqual(TestSupport.status(try XCTUnwrap(get("c", port: port)).head), 404)
    }

    // MARK: - Ranges

    func testPartialContent() throws {
        let (path, data) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get("pkg", "bytes=10-19", port: port))
        XCTAssertEqual(TestSupport.status(response.head), 206)
        XCTAssertEqual(TestSupport.header("Content-Range", in: response.head), "bytes 10-19/1000")
        XCTAssertEqual(TestSupport.header("Content-Length", in: response.head), "10")
        XCTAssertEqual(response.body, data[10...19])
    }

    func testOpenEndedRange() throws {
        let (path, data) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get("pkg", "bytes=990-", port: port))
        XCTAssertEqual(TestSupport.status(response.head), 206)
        XCTAssertEqual(TestSupport.header("Content-Range", in: response.head), "bytes 990-999/1000")
        XCTAssertEqual(response.body, data[990...999])
    }

    func testSuffixRange() throws {
        let (path, data) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get("pkg", "bytes=-16", port: port))
        XCTAssertEqual(TestSupport.status(response.head), 206)
        XCTAssertEqual(response.body, data[984...999])
    }

    func testUnsatisfiableRange() throws {
        let (path, _) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get("pkg", "bytes=5000-", port: port))
        XCTAssertEqual(TestSupport.status(response.head), 416)
        XCTAssertEqual(TestSupport.header("Content-Range", in: response.head), "bytes */1000")
        XCTAssertEqual(TestSupport.header("Accept-Ranges", in: response.head), "bytes")
        XCTAssertTrue(response.body.isEmpty)
    }

    func testCORSHeaders() throws {
        let (path, _) = fixture(8)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(get(port: port))
        XCTAssertEqual(TestSupport.header("Access-Control-Allow-Origin", in: response.head), "*")
    }

    // MARK: - Keep-alive

    func testKeepAliveServesTwoRequests() throws {
        let (path, data) = fixture()
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let stream = TestSupport.drain(
            port: port,
            "GET /pkg HTTP/1.1\r\nHost: h\r\nConnection: keep-alive\r\nRange: bytes=0-9\r\n\r\n"
                + "GET /pkg HTTP/1.1\r\nHost: h\r\nConnection: close\r\nRange: bytes=10-19\r\n\r\n"
        )
        XCTAssertEqual(stream.components(separatedBy: "HTTP/1.1 206").count - 1, 2)
        XCTAssertTrue(stream.contains("Content-Range: bytes 0-9/1000"), stream)
        XCTAssertTrue(stream.contains("Content-Range: bytes 10-19/1000"), stream)
        XCTAssertEqual(data.count, 1000)
    }

    // MARK: - Catalog / icon / manifest

    func testCatalog() throws {
        let (path, _) = fixture(4)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }
        server.catalogProvider = {
            [
                CatalogEntry(id: "abc", title: "Ga\"me", titleId: "CUSA00001", size: 1234, hasIcon: true),
                CatalogEntry(id: "def", title: "Other", titleId: "CUSA00002", size: 42),
            ]
        }

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /catalog HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(TestSupport.header("Content-Type", in: response.head), "application/json")
        let text = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("[{") && text.hasSuffix("}]"), text)
        XCTAssertTrue(text.contains("\"id\":\"abc\""), text)
        XCTAssertTrue(text.contains("\"title\":\"Ga\\\"me\""), text)
        XCTAssertTrue(text.contains("\"hasIcon\":true"), text)
        XCTAssertTrue(text.contains("\"hasIcon\":false"), text)
    }

    func testEmptyCatalogWithoutProvider() throws {
        let (path, _) = fixture(4)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /catalog HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "[]")
    }

    func testIcon() throws {
        let (path, _) = fixture(4)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        server.registerIcon(png, for: "cover")

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /icon/cover HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(TestSupport.header("Content-Type", in: response.head), "image/png")
        XCTAssertEqual(response.body, png)

        let missing = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /icon/none HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(missing.head), 404)
    }

    func testManifest() throws {
        let (path, _) = fixture(4)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }
        let manifest = PS4Installer.buildManifest(url: "http://127.0.0.1/pkg", fileSize: 10)
        server.registerManifest(manifest, for: "abc")

        let response = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /json/abc.json HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), manifest)

        let missing = try XCTUnwrap(
            TestSupport.exchange(port: port, "GET /json/none.json HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n")
        )
        XCTAssertEqual(TestSupport.status(missing.head), 404)
    }

    // MARK: - Revoke / progress / pieces

    func testRevokeAndUnrevoke() throws {
        let (path, _) = fixture(16)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        server.revoke("pkg")
        XCTAssertEqual(TestSupport.status(try XCTUnwrap(get(port: port)).head), 404)
        server.unrevoke("pkg")
        XCTAssertEqual(TestSupport.status(try XCTUnwrap(get(port: port)).head), 200)
    }

    func testProgressCounters() throws {
        let (path, _) = fixture(500)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }

        let counter = Counter()
        let sizes = Counter()
        server.onProgress = { served, size in
            counter.set(served)
            sizes.set(size)
        }

        _ = try XCTUnwrap(get("pkg", "bytes=0-99", port: port))
        XCTAssertEqual(server.servedBytes, 100)
        XCTAssertEqual(server.servedBytes(for: "pkg"), 100)
        XCTAssertEqual(counter.value, 100)
        XCTAssertEqual(sizes.value, 500)

        server.resetServed("pkg")
        XCTAssertEqual(server.servedBytes(for: "pkg"), 0)
    }

    func testPiecesAreServedAndCounted() throws {
        let (path, data) = fixture(1000)
        let (server, port) = try startServer(files: [:])
        defer { server.stop() }
        server.registerPieces(id: "game", path: path, count: 4)

        XCTAssertEqual(RangeHTTPServer.pieceIdentifier("game", 2), "game.p2")
        for index in 0..<4 {
            let response = try XCTUnwrap(get("game.p\(index)", port: port))
            XCTAssertEqual(TestSupport.status(response.head), 200)
            let start = index * 250
            XCTAssertEqual(response.body, data[start..<(start + 250)])
        }
        // Per-id progress follows the parent id.
        XCTAssertEqual(server.servedBytes(for: "game"), 1000)
        XCTAssertEqual(server.totalBytes(), 1000)

        server.unregisterPieces(id: "game")
        XCTAssertEqual(TestSupport.status(try XCTUnwrap(get("game.p0", port: port)).head), 404)
    }

    func testRegisteredRangeSource() throws {
        let (path, data) = fixture(600)
        let (server, port) = try startServer(files: [:])
        defer { server.stop() }
        let slice = try XCTUnwrap(RangeSource(fileAtPath: path, sliceOffset: 100, sliceLength: 200))
        server.register(slice, for: "slice")

        let response = try XCTUnwrap(get("slice", port: port))
        XCTAssertEqual(TestSupport.status(response.head), 200)
        XCTAssertEqual(response.body, data[100..<300])

        let partial = try XCTUnwrap(get("slice", "bytes=10-19", port: port))
        XCTAssertEqual(partial.body, data[110...119])
        XCTAssertEqual(TestSupport.header("Content-Range", in: partial.head), "bytes 10-19/200")
    }

    func testFileSizeAndStoppedServer() throws {
        let (path, _) = fixture(333)
        let (server, port) = try startServer(files: ["pkg": path])
        XCTAssertEqual(server.fileSize(for: "pkg"), 333)
        XCTAssertNil(server.fileSize(for: "nope"))
        XCTAssertTrue(server.isRunning)
        server.stop()
        XCTAssertFalse(server.isRunning)
        // Nothing is listening any more.
        XCTAssertNil(TestSupport.exchange(port: port, "GET /pkg HTTP/1.1\r\nHost: h\r\nConnection: close\r\n\r\n"))
    }

    func testRequestLog() throws {
        let (path, _) = fixture(8)
        let (server, port) = try startServer(files: ["pkg": path])
        defer { server.stop() }
        let log = LogBox()
        server.onRequestLog = { log.append($0) }

        _ = try XCTUnwrap(get(port: port))
        let entries = log.lines
        XCTAssertTrue(entries.contains { $0.contains("GET /pkg") }, "\(entries)")
    }
}

/// Lock-protected counter for progress callbacks (Swift 6 concurrency).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0

    func set(_ value: Int64) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ line: String) {
        lock.lock()
        items.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
