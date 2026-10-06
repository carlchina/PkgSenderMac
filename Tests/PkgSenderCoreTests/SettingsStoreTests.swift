import XCTest
@testable import PkgSenderCore

/// Settings persistence: location, round-trip, clamping and atomic writes.
final class SettingsStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        directory = Fixtures.makeDirectory()
        store = SettingsStore(applicationSupportDirectory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testFileLivesUnderApplicationSupport() {
        XCTAssertEqual(store.fileURL.path,
                       directory.appendingPathComponent("PkgSender/settings.json").path)
        XCTAssertTrue(SettingsStore.standard.fileURL.path.hasSuffix("PkgSender/settings.json"))
        XCTAssertTrue(SettingsStore.standard.fileURL.path.contains("Application Support"))
    }

    func testMissingFileYieldsDefaults() {
        XCTAssertFalse(store.exists)
        XCTAssertEqual(store.load().psIP, "192.168.1.105")
        XCTAssertEqual(store.load().chunkSize, AppSettings.defaultChunkSize)
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.psIP = "10.0.0.7"
        settings.pcIP = "10.0.0.9"
        settings.remoteDir = "/data/games"
        settings.chunkSize = 4 * 1024 * 1024
        settings.updateCheck = false
        settings.aboutShown = true
        settings.libraryRoots = ["/Volumes/Games"]

        try store.save(settings)
        XCTAssertTrue(store.exists)
        let loaded = store.load()
        XCTAssertEqual(loaded.psIP, "10.0.0.7")
        XCTAssertEqual(loaded.pcIP, "10.0.0.9")
        XCTAssertEqual(loaded.remoteDir, "/data/games")
        XCTAssertEqual(loaded.chunkSize, 4 * 1024 * 1024)
        XCTAssertFalse(loaded.updateCheck)
        XCTAssertTrue(loaded.aboutShown)
        XCTAssertEqual(loaded.libraryRoots, ["/Volumes/Games"])
    }

    /// A hand-edited or half-written file must fall back to defaults, not
    /// crash — the app has to survive its own settings file.
    func testCorruptFileFallsBackToDefaults() throws {
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load().psIP, "192.168.1.105")
    }

    func testOutOfRangeChunkSizeIsClamped() {
        var settings = AppSettings()
        settings.chunkSize = 1
        XCTAssertEqual(settings.normalized.chunkSize, AppSettings.chunkSizeRange.lowerBound)
        settings.chunkSize = Int.max
        XCTAssertEqual(settings.normalized.chunkSize, AppSettings.chunkSizeRange.upperBound)
    }

    func testRemoteDirIsNormalised() {
        var settings = AppSettings()
        settings.remoteDir = "  data/games//  "
        XCTAssertEqual(settings.normalized.remoteDir, "/data/games")
        settings.remoteDir = ""
        XCTAssertEqual(settings.normalized.remoteDir, "/data/homebrew")
    }

    func testIPv4SanityCheck() {
        XCTAssertTrue(AppSettings.looksLikeIPv4("192.168.1.1"))
        XCTAssertFalse(AppSettings.looksLikeIPv4("192.168.1"))
        XCTAssertFalse(AppSettings.looksLikeIPv4("192.168.1.256"))
        XCTAssertFalse(AppSettings.looksLikeIPv4("console.local"))
    }

    /// Saving twice in a row must leave one readable file behind (no
    /// half-written JSON, no leftover temp files).
    func testRepeatedSaveLeavesOneFile() throws {
        var settings = AppSettings(psIP: "10.0.0.1", pcIP: "10.0.0.2")
        try store.save(settings)
        settings.psIP = "10.0.0.3"
        try store.save(settings)

        XCTAssertEqual(store.load().psIP, "10.0.0.3")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers.map { $0.lastPathComponent }, ["settings.json"])
    }

    func testSaveCreatesMissingDirectory() throws {
        let nested = directory.appendingPathComponent("deep/nested")
        let store = SettingsStore(applicationSupportDirectory: nested)
        XCTAssertNoThrow(try store.save(AppSettings()))
        XCTAssertTrue(store.exists)
    }
}
