import XCTest
@testable import Uncoded

final class LensNameParserTests: XCTestCase {
    func testCameraAndCatalogFormatsNormalizeToSameIdentity() {
        // The camera writes "1:aperture/focal", catalogs write "focal mm f/aperture".
        XCTAssertEqual(
            LensNameParser.parse("Noctilux-M 1:1.2/50 ASPH."),
            LensNameParser.parse("Noctilux-M 50mm f/1.2 ASPH")
        )
        XCTAssertEqual(
            LensNameParser.parse("Summicron-M 1:2/35 ASPH."),
            LensNameParser.parse("Summicron-M 35mm f/2 ASPH (I)")
        )
    }

    func testParsesIdentityComponents() {
        let id = LensNameParser.parse("Summicron-M 1:2/28 ASPH.")
        XCTAssertEqual(id?.family, "summicron")
        XCTAssertEqual(id?.focalMM, 28)
        XCTAssertEqual(id?.apertureX10, 20)
    }

    func testMultiFocalLensUsesLastFocal() {
        // Tri-Elmar: camera lists "1:4/16-18-21", catalog "16-18-21mm f/4".
        XCTAssertEqual(
            LensNameParser.parse("Tri-Elmar-M 1:4/16-18-21 ASPH."),
            LensNameParser.parse("Tri-Elmar-M 16-18-21mm f/4 ASPH")
        )
    }

    func testCommaDecimalAperture() {
        // The catalog writes "Noctilux-M 75mm f/1,25" with a comma decimal.
        XCTAssertEqual(
            LensNameParser.parse("Noctilux-M 75mm f/1,25"),
            LensNameParser.parse("Noctilux-M 1:1.25/75 ASPH.")
        )
    }

    func testUnparseableReturnsNil() {
        XCTAssertNil(LensNameParser.parse("just words"))
        XCTAssertNil(LensNameParser.parse(""))
    }

    func testSixBitTableMatchesCameraString() {
        let match = SixBitTable.match(lensModel: "Summicron-M 1:2/28 ASPH.")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.code, "011010")
    }

    func testThirdPartyLensDoesNotMatchLeicaTable() {
        XCTAssertNil(SixBitTable.match(lensModel: "Voigtlander VM 35mm f/2 Ultron Aspherical"))
    }
}
