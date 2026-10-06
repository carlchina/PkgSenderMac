import XCTest
@testable import PkgSenderCore

/// Row construction: role, family key, subtitle and the Codable round-trip
/// that a saved library (and the queue) depends on.
final class GameItemTests: XCTestCase {

    func testRoleFromPS4Category() {
        XCTAssertEqual(GameItem.makeRole(format: "pkg", isDLC: false, contentType: "gd"), .game)
        XCTAssertEqual(GameItem.makeRole(format: "pkg", isDLC: false, contentType: "gp"), .patch)
        XCTAssertEqual(GameItem.makeRole(format: "pkg", isDLC: true, contentType: "ac"), .dlc)
    }

    /// Any non-pkg container is an image the console mounts, not installs.
    func testEveryNonPkgFormatIsAnImage() {
        for format in ["exfat", "ffpfsc", "ffpkg", "folder"] {
            XCTAssertEqual(GameItem.makeRole(format: format, isDLC: false, contentType: "gd"),
                           .image, "\(format) must be an image")
        }
    }

    func testRoleRankOrdersFamilies() {
        XCTAssertLessThan(GameRole.game.rank, GameRole.patch.rank)
        XCTAssertLessThan(GameRole.patch.rank, GameRole.dlc.rank)
        XCTAssertLessThan(GameRole.dlc.rank, GameRole.image.rank)
    }

    func testBuiltFromPkgInfo() {
        var info = PkgInfo()
        info.title = "Alpha Quest"
        info.contentId = "EP0002-CUSA00001_00-GAME0000000000"
        info.titleId = "CUSA00001"
        info.contentType = "gp"
        info.version = "v1.06"
        info.platform = "PS4"
        info.packageSize = 3 * 1024 * 1024
        info.digest = "AABB"
        info.iconData = Fixtures.pngIcon

        let item = GameItem(path: "/Volumes/Games/alpha.pkg", info: info)
        XCTAssertEqual(item.title, "Alpha Quest")
        XCTAssertEqual(item.role, .patch)
        XCTAssertEqual(item.familyKey, "CUSA00001")
        XCTAssertEqual(item.version, "1.06")            // leading v stripped
        XCTAssertEqual(item.platform, "PS4")
        XCTAssertEqual(item.digest, "AABB")
        XCTAssertEqual(item.sizeText, "3.00 MB")
        XCTAssertTrue(item.hasCover)
        XCTAssertTrue(item.isPS4)
        XCTAssertFalse(item.isPS5)
        XCTAssertEqual(item.meta, "CUSA00001 • v1.06 • Patch")
        XCTAssertEqual(item.id, StableID.forPath("/Volumes/Games/alpha.pkg"))
    }

    func testTitleFallsBackToFileName() {
        let item = GameItem(path: "/tmp/Mystery.pkg", info: PkgInfo())
        XCTAssertEqual(item.title, "Mystery.pkg")
        XCTAssertEqual(item.platform, "PKG")            // unknown platform, pkg format
    }

    func testPlatformLabelForImages() {
        var info = PkgInfo()
        info.platform = "PS5"
        info.format = "exfat"
        let item = GameItem(path: "/tmp/x.exfat", info: info)
        XCTAssertEqual(item.platform, "PS5 • exfat")
        XCTAssertEqual(item.role, .image)
        XCTAssertTrue(item.isImage)
    }

    func testSearchHaystack() {
        let item = GameItem(path: "/tmp/My Game.pkg", title: "Alpha Quest",
                            contentId: "EP0002-CUSA00001_00-X", titleId: "CUSA00001")
        let hay = item.searchHaystack
        XCTAssertTrue(hay.contains("alpha quest"))
        XCTAssertTrue(hay.contains("cusa00001"))
        XCTAssertTrue(hay.contains("my game.pkg"))
    }

    func testCodableRoundTrip() throws {
        let item = GameItem(path: "/tmp/a.pkg", title: "Alpha", contentId: "EP0002-X",
                            titleId: "CUSA00001", contentType: "gd", version: "1.00",
                            platform: "PS4", format: "pkg", sizeBytes: 2048,
                            iconData: Fixtures.pngIcon, digest: "AA", role: .game,
                            isFolder: false)
        let data = try JSONEncoder().encode(item)
        let back = try JSONDecoder().decode(GameItem.self, from: data)
        XCTAssertEqual(back, item)
        XCTAssertEqual(back.iconData, Fixtures.pngIcon)
        XCTAssertEqual(back.role, .game)
    }

    // MARK: Queue

    func testQueueEntryClampsPercent() {
        let game = GameItem(path: "/tmp/a.pkg", title: "Alpha")
        let entry = QueueEntry(game: game, percent: 4.2, bytesSent: -5)
        XCTAssertEqual(entry.percent, 1)
        XCTAssertEqual(entry.bytesSent, 0)
        XCTAssertEqual(entry.id, game.id)
    }

    func testQueueStateTransitions() {
        XCTAssertTrue(QueueState.sending.canPause)
        XCTAssertFalse(QueueState.done.canPause)
        XCTAssertTrue(QueueState.done.isFinished)
        XCTAssertFalse(QueueState.paused.isFinished)
        XCTAssertEqual(QueueState.paused.pauseGlyph, "▶")
        XCTAssertEqual(QueueState.sending.pauseGlyph, "⏸")
        XCTAssertTrue(QueueState(rawValue: "copying")?.canPause == true)
    }

    func testResendRequiresResumeAndFailure() {
        let game = GameItem(path: "/tmp/a.pkg", title: "Alpha")
        var entry = QueueEntry(game: game, state: .failed, canResume: true)
        XCTAssertTrue(entry.canResend)
        entry.state = .done
        XCTAssertFalse(entry.canResend)
        entry = QueueEntry(game: game, state: .failed, canResume: false)
        XCTAssertFalse(entry.canResend)
    }

    func testQueueEntryRoundTrip() throws {
        let game = GameItem(path: "/tmp/a.pkg", title: "Alpha", sizeBytes: 1000)
        let entry = QueueEntry(game: game, state: .sending, percent: 0.5, bytesSent: 500)
        let back = try JSONDecoder().decode(
            QueueEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back.state, .sending)
        XCTAssertEqual(back.percent, 0.5)
        XCTAssertEqual(back.game.title, "Alpha")
        XCTAssertEqual(back.progressBytes, 500)
    }
}
