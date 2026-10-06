import XCTest
@testable import PkgSenderCore

/// The bounds checks every parser relies on. `Data.subdata(in:)` traps on an
/// out-of-range range, so these accessors must return nil instead.
final class ByteReaderTests: XCTestCase {

    func testReadsBothEndians() {
        let reader = ByteReader(Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
        XCTAssertEqual(reader.u8(at: 0), 0x01)
        XCTAssertEqual(reader.u16le(at: 0), 0x0201)
        XCTAssertEqual(reader.u16be(at: 0), 0x0102)
        XCTAssertEqual(reader.u32le(at: 0), 0x0403_0201)
        XCTAssertEqual(reader.u32be(at: 0), 0x0102_0304)
        XCTAssertEqual(reader.u64le(at: 0), 0x0807_0605_0403_0201)
        XCTAssertEqual(reader.u64be(at: 0), 0x0102_0304_0506_0708)
    }

    func testOutOfRangeReadsReturnNil() {
        let reader = ByteReader(Data([0x01, 0x02, 0x03]))
        XCTAssertNil(reader.u8(at: 3))
        XCTAssertNil(reader.u8(at: -1))
        XCTAssertNil(reader.u16le(at: 2))
        XCTAssertNil(reader.u32be(at: 0))          // only 3 bytes available
        XCTAssertNil(reader.u64le(at: -8))
        XCTAssertNil(reader.bytes(at: 0, count: 4))
        XCTAssertNil(reader.bytes(at: 2, count: -1))
        XCTAssertNil(reader.data(at: 4, count: 1))
    }

    /// A huge count must not overflow `offset + count` into a "valid" range.
    func testExtremeCountDoesNotOverflow() {
        let reader = ByteReader(Data([0x01, 0x02]))
        XCTAssertNil(reader.bytes(at: 1, count: Int.max))
        XCTAssertNil(reader.bytes(at: 0, count: Int.max))
    }

    func testFixedStringStopsAtNUL() {
        var raw = Data("CUSA00001".utf8)
        raw.append(contentsOf: [0x00, 0x41, 0x41])
        let reader = ByteReader(raw)
        XCTAssertEqual(reader.fixedString(at: 0, length: 12), "CUSA00001")
        XCTAssertNil(reader.fixedString(at: 10, length: 8))     // runs past the end
        XCTAssertEqual(reader.paddedString(at: 0, length: 12), "CUSA00001AA")
    }

    func testCStringClipsAtBufferEnd() {
        let reader = ByteReader(Data("ABCD".utf8))
        XCTAssertEqual(reader.cString(at: 0, limit: 64), "ABCD")
        XCTAssertEqual(reader.cString(at: 2, limit: 2), "CD")
        XCTAssertNil(reader.cString(at: 4, limit: 1))
    }

    func testMemorySourceRefusesShortRanges() {
        let source = MemoryByteSource(Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(source.byteCount, 3)
        XCTAssertEqual(source.read(at: 0, count: 3)?.count, 3)
        XCTAssertNil(source.read(at: 1, count: 3))
        XCTAssertNil(source.read(at: 4, count: 1))
        XCTAssertEqual(source.read(at: 3, count: 0), Data())
    }
}
