import XCTest
@testable import PkgSenderCore

/// Package reading against synthetic CNT / FIH containers: PS4 `param.sfo`,
/// PS5 `param.json`, cover art and the header digest.
final class PkgReaderTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = Fixtures.makeDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func file(_ name: String, _ data: Data) -> URL {
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(Fixtures.write(data, to: url), "could not write \(name)")
        return url
    }

    // MARK: PS4

    func testReadsPS4ParamSFO() throws {
        let url = file("game.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest",
            contentId: "EP0002-CUSA00001_00-GAME0000000000",
            titleId: "CUSA00001",
            category: "gd",
            version: "1.06"))

        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertEqual(info.title, "Alpha Quest")
        XCTAssertEqual(info.contentId, "EP0002-CUSA00001_00-GAME0000000000")
        XCTAssertEqual(info.titleId, "CUSA00001")
        XCTAssertEqual(info.contentType, "gd")
        XCTAssertEqual(info.version, "1.06")
        XCTAssertEqual(info.platform, "PS4")
        XCTAssertEqual(info.format, "pkg")
        XCTAssertEqual(info.packageSize, Int64(url.fileSizeOnDisk))
        XCTAssertFalse(info.isDLC)
    }

    func testPS4UpdateCategoryIsNotDLC() throws {
        let url = file("patch.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest Update",
            contentId: "EP0002-CUSA00001_00-GAMEPATCH000001",
            titleId: "CUSA00001",
            category: "gp"))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertEqual(info.contentType, "gp")
        XCTAssertFalse(info.isDLC)
    }

    func testPS4AddOnCategoryIsDLC() throws {
        let url = file("dlc.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest Pack",
            contentId: "EP0002-CUSA00001_00-GAMEDLC00000001",
            titleId: "CUSA00001",
            category: "ac"))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertTrue(info.isDLC)
    }

    func testReadsCoverArt() throws {
        let url = file("withicon.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest",
            contentId: "EP0002-CUSA00001_00-GAME0000000000",
            titleId: "CUSA00001",
            icon: Fixtures.pngIcon))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertEqual(info.iconData, Fixtures.pngIcon)
    }

    func testNoCoverWhenNoIconEntry() throws {
        let url = file("noicon.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest",
            contentId: "EP0002-CUSA00001_00-GAME0000000000",
            titleId: "CUSA00001"))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertNil(info.iconData)
    }

    /// A non-PNG payload on the icon entry must be rejected — patch packages
    /// sometimes ship an unrelated file there, and a bogus cover used to land
    /// on the wrong card in family view.
    func testNonPNGIconPayloadIsRejected() throws {
        let url = file("bogusicon.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest",
            contentId: "EP0002-CUSA00001_00-GAME0000000000",
            titleId: "CUSA00001",
            icon: Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertNil(info.iconData)
    }

    func testReadsHeaderDigest() throws {
        let digest = Data((0..<32).map { UInt8($0) })
        let url = file("digest.pkg", Fixtures.ps4Pkg(
            title: "Alpha Quest",
            contentId: "EP0002-CUSA00001_00-GAME0000000000",
            titleId: "CUSA00001",
            digest: digest))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertEqual(info.digest, "000102030405060708090A0B0C0D0E0F"
            + "101112131415161718191A1B1C1D1E1F")
        XCTAssertEqual(info.digest.count, 64)
    }

    // MARK: PS5

    func testReadsPS5ParamJSON() throws {
        let url = file("ps5.pkg", Fixtures.ps5Pkg(
            contentId: "EP9000-PPSA01325_00-MYGAME0000000000",
            title: "Five Quest",
            titleId: "PPSA01325",
            version: "2.00",
            icon: Fixtures.pngIcon,
            digest: Data(repeating: 0xAB, count: 32)))

        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertEqual(info.title, "Five Quest")
        XCTAssertEqual(info.contentId, "EP9000-PPSA01325_00-MYGAME0000000000")
        XCTAssertEqual(info.titleId, "PPSA01325")
        XCTAssertEqual(info.version, "2.00")
        XCTAssertEqual(info.platform, "PS5")
        XCTAssertEqual(info.iconData, Fixtures.pngIcon)
        XCTAssertTrue(info.digest.hasPrefix("ABABAB"))
        XCTAssertFalse(info.isDLC)
    }

    /// An official (0x80) FIH is Retail; a cleared flag is Debug.
    func testPS5SignatureFlavour() throws {
        let retail = file("retail.pkg", Fixtures.ps5Pkg(
            contentId: "EP9000-PPSA01325_00-MYGAME0000000000",
            title: "Five Quest", titleId: "PPSA01325", official: true))
        let debug = file("debug.pkg", Fixtures.ps5Pkg(
            contentId: "EP9000-PPSA01325_00-MYGAME0000000000",
            title: "Five Quest", titleId: "PPSA01325", official: false))
        let retailInfo = try XCTUnwrap(PkgReader.read(url: retail))
        let debugInfo = try XCTUnwrap(PkgReader.read(url: debug))
        XCTAssertTrue(retailInfo.description.contains("Retail"))
        XCTAssertTrue(debugInfo.description.contains("Debug"))
    }

    func testPS5DLCHeuristic() throws {
        let url = file("ps5dlc.pkg", Fixtures.ps5Pkg(
            contentId: "EP9000-PPSA01325_00-MYGAMEDLC0000000",
            title: "Five Quest Expansion", titleId: "PPSA01325"))
        let info = try XCTUnwrap(PkgReader.read(url: url))
        XCTAssertTrue(info.isDLC)
    }

    // MARK: Rejections and helpers

    func testUnrecognisedFileReturnsNil() {
        let url = file("random.pkg", Data(repeating: 0x41, count: 8192))
        XCTAssertNil(PkgReader.read(url: url))
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(PkgReader.read(url: directory.appendingPathComponent("nope.pkg")))
    }

    /// An FIH whose CNT offset points past the end must not be followed.
    func testFIHOffsetOutOfRangeIsRejected() {
        var blob = Fixtures.ps5Pkg(contentId: "EP9000-PPSA01325_00-X",
                                   title: "Five", titleId: "PPSA01325")
        var bogus = UInt64(0xFFFF_0000).littleEndian
        blob.replaceSubrange(0x58..<0x60, with: Data(bytes: &bogus, count: 8))
        XCTAssertNil(PkgReader.read(url: file("badoffset.pkg", blob)))
    }

    /// exFAT images: `sce_sys/param.json` + `icon0.png` read out of a
    /// synthetic image (no FAT chain, contiguous clusters).
    func testReadsExfatImage() throws {
        let json = Data("""
        {"titleId":"PPSA01325","contentId":"EP9000-PPSA01325_00-X",
         "contentVersion":"1.00",
         "localizedParameters":{"defaultLanguage":"en-US",
                                "en-US":{"titleName":"Five Quest"}}}
        """.utf8)
        let url = file("game.exfat", Fixtures.exfat(paramJSON: json,
                                                    icon: Fixtures.pngIcon))

        let info = try XCTUnwrap(ExfatReader.read(url: url))
        XCTAssertEqual(info.title, "Five Quest")
        XCTAssertEqual(info.titleId, "PPSA01325")
        XCTAssertEqual(info.contentId, "EP9000-PPSA01325_00-X")
        XCTAssertEqual(info.version, "1.00")
        XCTAssertEqual(info.format, "exfat")
        XCTAssertEqual(info.iconData, Fixtures.pngIcon)
    }

    /// A wrong OEM name must be rejected outright, not walked anyway.
    func testNonExfatDataIsRejected() throws {
        let url = file("notanimage.exfat", Data(repeating: 0x41, count: 4096))
        XCTAssertNil(ExfatReader.read(url: url))
        // ...and the library falls back to the file-name stub.
        let item = try XCTUnwrap(GameReader.read(url: url))
        XCTAssertEqual(item.format, "exfat")
        XCTAssertEqual(item.title, "notanimage.exfat")
    }

    func testTitleIdFromContentId() {
        XCTAssertEqual(PkgReader.titleIdFromContentId("EP9000-PPSA01325_00-ABCDEFG"),
                       "PPSA01325")
        XCTAssertEqual(PkgReader.titleIdFromContentId("EP0002-CUSA00001_00-X"), "CUSA00001")
        XCTAssertEqual(PkgReader.titleIdFromContentId("nonsense"), "")
    }

    func testDLCHeuristic() {
        XCTAssertTrue(PkgReader.isDLCHeuristic(title: "Season Pass", contentId: ""))
        XCTAssertTrue(PkgReader.isDLCHeuristic(title: "", contentId: "EP9000-PPSA_x-DLC"))
        XCTAssertFalse(PkgReader.isDLCHeuristic(title: "Five Quest", contentId: "EP9000-X"))
    }
}

private extension URL {
    /// Size via the file system — what the scanner reports for a package.
    var fileSizeOnDisk: Int64 {
        let values = try? resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
