import XCTest
@testable import Uncoded

final class SixBitTableTests: XCTestCase {
    func testTableLoadsFromBundle() {
        XCTAssertGreaterThan(SixBitTable.all.count, 50, "bundled sixbit_codes.json should load")
    }

    func testCodesAreSixBinaryDigits() {
        for row in SixBitTable.all {
            XCTAssertEqual(row.code.count, 6, row.lensName)
            XCTAssertTrue(row.code.allSatisfy { $0 == "0" || $0 == "1" }, row.lensName)
        }
    }

    func testKnownCodeGroupsGenerations() {
        // 011010 is shared by the Summicron-M 28/2 generations.
        let entries = SixBitTable.byCode["011010"]
        XCTAssertNotNil(entries)
        XCTAssertTrue(entries!.allSatisfy { $0.lensName.contains("Summicron-M 28mm") })
    }

    func testBitsMatchCodeString() {
        let row = SixBitCode(code: "110100", lensName: "x", productCodes: [], leicaIndex: "")
        XCTAssertEqual(row.bits, [true, true, false, true, false, false])
    }
}
