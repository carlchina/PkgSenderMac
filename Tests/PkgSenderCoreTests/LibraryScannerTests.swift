import XCTest
@testable import PkgSenderCore

/// Media library scanning: recursion, image stubs, dedup and family linking.
final class LibraryScannerTests: XCTestCase {
    private var root: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    private var scanner: LibraryScanner = LibraryScanner()

    override func setUp() {
        super.setUp()
        root = Fixtures.makeDirectory()
        scanner = LibraryScanner()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func pkg(_ name: String, title: String, titleId: String,
                     contentId: String, category: String = "gd",
                     in folder: URL? = nil) -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        XCTAssertTrue(Fixtures.write(Fixtures.ps4Pkg(title: title, contentId: contentId,
                                                     titleId: titleId, category: category),
                                     to: url))
        return url
    }

    // MARK: Discovery

    func testFindsPackagesRecursively() {
        let nested = root.appendingPathComponent("a/b/c", isDirectory: true)
        try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        pkg("deep.pkg", title: "Deep One", titleId: "CUSA00009",
            contentId: "EP0002-CUSA00009_00-X", in: nested)

        let items = scanner.scan(roots: [root])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.title, "Deep One")
    }

    /// The upstream C# drop handler accepted `.pkg` only, so dragging an
    /// image did nothing at all. Every container extension must be readable.
    func testImagesAreAccepted() {
        Fixtures.write(Fixtures.ps5Pkg(contentId: "EP9000-PPSA01325_00-X",
                                       title: "Five", titleId: "PPSA01325"),
                       to: root.appendingPathComponent("game.pkg"))
        Fixtures.write(Data(repeating: 0x00, count: 8192),
                       to: root.appendingPathComponent("image.exfat"))
        Fixtures.write(Data(repeating: 0x00, count: 4096),
                       to: root.appendingPathComponent("asset.ffpfsc"))
        Fixtures.write(Data(repeating: 0x00, count: 4096),
                       to: root.appendingPathComponent("disk.ffpkg"))

        let items = scanner.scan(roots: [root])
        XCTAssertEqual(Set(items.map(\.format)), ["pkg", "exfat", "ffpfsc", "ffpkg"])
        XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty })
    }

    /// An image that cannot be walked is still listed, identified from the
    /// file name — otherwise the row disappears from the library entirely.
    func testUnreadableImageFallsBackToFilenameStub() throws {
        let url = root.appendingPathComponent("PPSA01325.exfat")
        Fixtures.write(Data(repeating: 0x00, count: 8192), to: url)

        let item = try XCTUnwrap(scanner.scan(roots: [root]).first)
        XCTAssertEqual(item.titleId, "PPSA01325")
        XCTAssertEqual(item.title, "PPSA01325")
        XCTAssertEqual(item.format, "exfat")
        XCTAssertEqual(item.role, .image)
        XCTAssertNil(item.iconData)
    }

    func testDroppedImagesAreRead() {
        let exfat = root.appendingPathComponent("PPSA01325.exfat")
        let ffpkg = root.appendingPathComponent("game.ffpkg")
        Fixtures.write(Data(repeating: 0x00, count: 8192), to: exfat)
        Fixtures.write(Data(repeating: 0x00, count: 4096), to: ffpkg)

        let items = scanner.read(urls: [exfat, ffpkg])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.format)), ["exfat", "ffpkg"])
    }

    func testUnknownExtensionIsIgnored() {
        Fixtures.write(Data(repeating: 0x00, count: 1024),
                       to: root.appendingPathComponent("notes.txt"))
        XCTAssertTrue(scanner.scan(roots: [root]).isEmpty)
    }

    func testGameFolderIsCollectedButNotDescended() throws {
        Fixtures.gameFolder(root, name: "AppFolder", title: "Folder Game",
                            titleId: "PPSA09999")
        // A package inside the folder must not show up separately.
        let folder = root.appendingPathComponent("AppFolder", isDirectory: true)
        pkg("inner.pkg", title: "Inner", titleId: "CUSA11111",
            contentId: "EP0002-CUSA11111_00-X", in: folder)

        let items = scanner.scan(roots: [root])
        XCTAssertEqual(items.count, 1)
        let first = try XCTUnwrap(items.first)
        XCTAssertTrue(first.isFolder)
        XCTAssertEqual(first.format, "folder")
    }

    // MARK: Dedup

    func testSamePackageInTwoPlacesIsListedOnce() {
        let data = Fixtures.ps4Pkg(title: "Alpha", contentId: "EP0002-CUSA00001_00-X",
                                   titleId: "CUSA00001")
        Fixtures.write(data, to: root.appendingPathComponent("one.pkg"))
        Fixtures.write(data, to: root.appendingPathComponent("copy.pkg"))

        let items = scanner.scan(roots: [root])
        XCTAssertEqual(items.count, 1, "identical content must not appear twice")
    }

    func testSamePathIsNotRepeated() {
        let url = root.appendingPathComponent("one.pkg")
        Fixtures.write(Fixtures.ps4Pkg(title: "Alpha", contentId: "EP0002-CUSA00001_00-X",
                                       titleId: "CUSA00001"), to: url)
        let twice = [url, url]
        XCTAssertEqual(LibraryScanner.deduplicate(twice.map {
            GameItem(path: $0.path, title: "Alpha", contentId: "EP0002-CUSA00001_00-X")
        }).count, 1)
    }

    /// An update shares the title id but has its own content id, so it must
    /// survive dedup and stay linked to its base game.
    func testUpdateSurvivesDedup() {
        pkg("base.pkg", title: "Alpha", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-BASE000000")
        pkg("update.pkg", title: "Alpha Update", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-PATCH00000", category: "gp")

        let items = scanner.scan(roots: [root])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items.map(\.role)), [.game, .patch])
    }

    // MARK: Families

    func testFamilyLinking() throws {
        pkg("base.pkg", title: "Alpha", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-BASE000000")
        pkg("update.pkg", title: "Alpha Update", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-PATCH00000", category: "gp")
        pkg("dlc.pkg", title: "Alpha Pack", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-DLC0000000", category: "ac")

        let items = scanner.scan(roots: [root])
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { $0.hasFamily })
        XCTAssertTrue(items.allSatisfy { $0.familyCount == 3 })
        XCTAssertEqual(Set(items.map(\.familyKey)), ["CUSA00001"])
        // The tooltip names every member, so the UI can explain the link.
        let base = try XCTUnwrap(items.first)
        XCTAssertTrue(base.familyTip.contains("Alpha Pack"))
    }

    /// Rows with no title id are never merged — a shared file name is not
    /// evidence that two files belong together.
    func testRowsWithoutTitleIdAreNotLinked() {
        let a = GameItem(path: "/tmp/a.pkg", title: "Mystery", titleId: "")
        let b = GameItem(path: "/tmp/b.pkg", title: "Mystery", titleId: "")
        let linked = LibraryScanner.linkFamilies([a, b])
        XCTAssertTrue(linked.allSatisfy { !$0.hasFamily })
        XCTAssertNotEqual(linked[0].familyKey, linked[1].familyKey)
    }

    func testFamilyKeyUsesTitleId() {
        XCTAssertEqual(GameItem.makeFamilyKey(titleId: "cusa00001", path: "/x/y.pkg"),
                       "CUSA00001")
        XCTAssertEqual(GameItem.makeFamilyKey(titleId: "", path: "/x/My Game.pkg"),
                       "FILE:MY GAME.PKG")
    }

    // MARK: Progress and ordering

    func testProgressIsReported() {
        pkg("base.pkg", title: "Alpha", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-X")
        let box = ProgressBox()
        _ = scanner.scan(roots: [root], progress: { box.append($0) })
        XCTAssertFalse(box.lines.isEmpty)
        XCTAssertTrue(box.lines.contains { $0.contains("Reading") })
    }

    func testResultsAreSortedByTitle() {
        pkg("b.pkg", title: "Zulu", titleId: "CUSA00002",
            contentId: "EP0002-CUSA00002_00-X")
        pkg("a.pkg", title: "Alpha", titleId: "CUSA00001",
            contentId: "EP0002-CUSA00001_00-X")
        XCTAssertEqual(scanner.scan(roots: [root]).map(\.title), ["Alpha", "Zulu"])
    }

    func testMissingRootIsSkipped() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(scanner.scan(roots: [missing]).isEmpty)
    }
}

/// Non-Sendable collector so the `@Sendable` progress closure can be checked
/// from a test without hopping actors.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
