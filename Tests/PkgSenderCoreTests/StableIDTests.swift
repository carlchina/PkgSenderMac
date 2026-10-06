import XCTest
@testable import PkgSenderCore

final class StableIDTests: XCTestCase {

    func testFNV1aMatchesKnownVectors() {
        // FNV-1a 64 reference values: the hash must not drift, or every
        // cached id in a saved library would change meaning.
        XCTAssertEqual(StableID.fnv1a64(""), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(StableID.fnv1a64("a"), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(StableID.fnv1a64("foobar"), 0x8594_4171_f739_67e8)
    }

    func testHexIsZeroPaddedTo16Digits() {
        XCTAssertEqual(StableID.hex(0), "0000000000000000")
        XCTAssertEqual(StableID.hex(1), "0000000000000001")
        XCTAssertEqual(StableID.hex(UInt64.max), "ffffffffffffffff")
    }

    func testPathIdIsStableAndDistinct() {
        let a = StableID.forPath("/Volumes/Games/a.pkg")
        XCTAssertEqual(a, StableID.forPath("/Volumes/Games/a.pkg"))
        XCTAssertNotEqual(a, StableID.forPath("/Volumes/Games/b.pkg"))
        XCTAssertEqual(a.count, 16)
    }

    func testContentIdPrefersTitleId() {
        XCTAssertEqual(StableID.forContent(titleId: "CUSA00001", contentId: "EP0002-X"),
                       "tid-" + StableID.hex(StableID.fnv1a64("CUSA00001")))
        // No title id (typical for PS5 images): fall back to the content id.
        XCTAssertEqual(StableID.forContent(titleId: " ", contentId: "EP9000-X"),
                       "cid-" + StableID.hex(StableID.fnv1a64("EP9000-X")))
        XCTAssertEqual(StableID.forContent(titleId: "", contentId: ""), "none")
    }
}
