import XCTest
@testable import Uncoded

final class SearchTests: XCTestCase {
    func testAllTokensMustMatchInAnyOrder() {
        let fields: [String?] = ["Voigtlander VM 35mm f/2 Ultron Aspherical", "Voigtlander"]
        XCTAssertTrue(Search.matches("voigtlander ultron", in: fields))
        XCTAssertTrue(Search.matches("ultron voigtlander", in: fields))
        XCTAssertTrue(Search.matches("35 ultron", in: fields))
        XCTAssertFalse(Search.matches("voigtlander nokton", in: fields))
    }

    func testPartialTokensMatch() {
        let fields: [String?] = ["Summicron-M 28mm f/2 ASPH (I)"]
        XCTAssertTrue(Search.matches("summi 28", in: fields))
        XCTAssertTrue(Search.matches("cron asph", in: fields))
    }

    func testEmptyQueryAndNilFields() {
        XCTAssertTrue(Search.matches("", in: ["anything"]))
        XCTAssertTrue(Search.matches("   ", in: ["anything"]))
        XCTAssertFalse(Search.matches("x", in: [nil]))
    }
}
