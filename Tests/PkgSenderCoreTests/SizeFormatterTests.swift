import XCTest
@testable import PkgSenderCore

final class SizeFormatterTests: XCTestCase {

    func testBinaryUnits() {
        XCTAssertEqual(SizeFormatter.string(0), "0 B")
        XCTAssertEqual(SizeFormatter.string(1), "1 B")
        XCTAssertEqual(SizeFormatter.string(1023), "1023 B")
        XCTAssertEqual(SizeFormatter.string(1024), "1.00 KB")
        XCTAssertEqual(SizeFormatter.string(1536), "1.50 KB")
        XCTAssertEqual(SizeFormatter.string(1024 * 1024), "1.00 MB")
        XCTAssertEqual(SizeFormatter.string(4_294_967_296), "4.00 GB")
        XCTAssertEqual(SizeFormatter.string(1_099_511_627_776), "1.00 TB")
    }

    /// Unknown sizes arrive as -1 from some sources; they must not render as
    /// a negative number.
    func testNegativeSizeIsPlaceholder() {
        XCTAssertEqual(SizeFormatter.string(-1), "—")
        XCTAssertEqual(SizeFormatter.exact(-1), "—")
    }

    func testExactFormatsWithSeparators() {
        XCTAssertEqual(SizeFormatter.exact(0), "0 B")
        XCTAssertEqual(SizeFormatter.exact(1_234_567), "1,234,567 B")
    }
}
