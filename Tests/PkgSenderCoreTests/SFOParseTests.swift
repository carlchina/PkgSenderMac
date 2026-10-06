import XCTest
@testable import PkgSenderCore

/// `param.sfo` decoding: layout, endianness and the bounds checks that keep
/// a malformed blob from trapping.
final class SFOParseTests: XCTestCase {

    func testParsesStringEntries() throws {
        let data = Fixtures.sfo([
            ("TITLE", "Alpha"),
            ("CONTENT_ID", "EP0002-CUSA00001_00-GAME0000000000"),
            ("TITLE_ID", "CUSA00001"),
            ("CATEGORY", "gd"),
        ])
        let dict = try SFO.parse(data)
        XCTAssertEqual(SFO.string(dict, "TITLE"), "Alpha")
        XCTAssertEqual(SFO.string(dict, "TITLE_ID"), "CUSA00001")
        XCTAssertEqual(SFO.string(dict, "CATEGORY"), "gd")
        XCTAssertEqual(dict.count, 4)
    }

    func testEmptyStringIsDistinctFromMissingKey() throws {
        let dict = try SFO.parse(Fixtures.sfo([("TITLE", "")]))
        XCTAssertEqual(SFO.string(dict, "TITLE"), "")
        XCTAssertNil(dict["MISSING"])
    }

    func testIntegerEntryRendersAsUppercaseHex() throws {
        // SYSTEM_VER is an int32 in real packages; it must survive as hex
        // rather than being forced through a string conversion.
        var blob = Data([0x00, 0x50, 0x53, 0x46])
        blob.append(Fixtures.le32(0x0000_0101))
        blob.append(Fixtures.le32(0x24))                 // key table: 0x14 + 1*0x10
        blob.append(Fixtures.le32(0x24 + 4))             // data table ("SYS\0")
        blob.append(Fixtures.le32(1))
        blob.append(Fixtures.le16(0))                    // key offset
        blob.append(Fixtures.le16(0x0404))               // int32
        blob.append(Fixtures.le32(4))
        blob.append(Fixtures.le32(4))
        blob.append(Fixtures.le32(0))
        blob.append(Fixtures.cString("SYS"))
        blob.append(Fixtures.le32(0x0501_0000))

        let dict = try SFO.parse(blob)
        guard case .int(let value)? = dict["SYS"] else {
            return XCTFail("expected an int entry, got \(String(describing: dict["SYS"]))")
        }
        XCTAssertEqual(value, 0x0501_0000)
        XCTAssertEqual(dict["SYS"]?.text, "05010000")
    }

    func testUnknownEntryFormatIsSkippedNotFatal() throws {
        var blob = Data([0x00, 0x50, 0x53, 0x46])
        blob.append(Fixtures.le32(0x0000_0101))
        blob.append(Fixtures.le32(52))                   // key table: 0x14 + 2*0x10
        blob.append(Fixtures.le32(62))                   // data table: + "BIN\0" + "TITLE\0"
        blob.append(Fixtures.le32(2))
        // First entry: unknown binary format.
        blob.append(Fixtures.le16(0))
        blob.append(Fixtures.le16(0x0004))
        blob.append(Fixtures.le32(2))
        blob.append(Fixtures.le32(2))
        blob.append(Fixtures.le32(0))
        // Second entry: a normal string that must still be read.
        blob.append(Fixtures.le16(4))
        blob.append(Fixtures.le16(0x0204))
        blob.append(Fixtures.le32(3))
        blob.append(Fixtures.le32(3))
        blob.append(Fixtures.le32(2))
        blob.append(Fixtures.cString("BIN"))
        blob.append(Fixtures.cString("TITLE"))
        blob.append(Data([0x01, 0x02]))
        blob.append(Fixtures.cString("OK"))

        let dict = try SFO.parse(blob)
        XCTAssertEqual(SFO.string(dict, "TITLE"), "OK")
        XCTAssertNil(dict["BIN"])
    }

    func testRejectsBadMagicAndTruncatedHeader() {
        // Long enough to get past the size check: the magic must be rejected.
        var bad = Data([0x41, 0x42, 0x43, 0x44])
        bad.append(Data(count: 0x14))
        XCTAssertThrowsError(try SFO.parse(bad)) { error in
            XCTAssertEqual(error as? PkgParseError, .badMagic)
        }
        // Magic present but no header behind it.
        XCTAssertThrowsError(try SFO.parse(Data([0x00, 0x50, 0x53, 0x46]))) { error in
            XCTAssertEqual(error as? PkgParseError, .tooSmall)
        }
    }

    func testAbsurdEntryCountIsRejected() {
        var blob = Data([0x00, 0x50, 0x53, 0x46])
        blob.append(Fixtures.le32(0x0000_0101))
        blob.append(Fixtures.le32(0x14))
        blob.append(Fixtures.le32(0x14))
        blob.append(Fixtures.le32(0xFFFF_FFFF))     // would allocate wildly
        XCTAssertThrowsError(try SFO.parse(blob)) { error in
            XCTAssertEqual(error as? PkgParseError, .badHeader)
        }
    }

    /// A count that claims more entries than the buffer holds must stop at
    /// the buffer end instead of reading past it.
    func testTruncatedEntryTableStopsAtBufferEnd() throws {
        let data = Fixtures.sfo([("TITLE", "Alpha")])
        var blob = data
        // Claim ten entries; only one is present.
        blob.replaceSubrange(0x10..<0x14, with: Fixtures.le32(10))
        let dict = try SFO.parse(blob)
        XCTAssertEqual(SFO.string(dict, "TITLE"), "Alpha")
    }
}
