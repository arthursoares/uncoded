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
            LensNameParser.key(of: "Summicron-M 1:2/35 ASPH.")?.base,
            LensNameParser.key(of: "Summicron-M 35mm f/2 ASPH (I)")?.base
        )
    }

    func testParsesIdentityComponents() {
        let id = LensNameParser.parse("Summicron-M 1:2/28 ASPH.")
        XCTAssertEqual(id?.family, "summicron")
        XCTAssertEqual(id?.focalMM, 28)
        XCTAssertEqual(id?.apertureX100, 200)
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

    func testFastApertureKeepsHundredthPrecision() {
        // f/0.95 and f/1 are different lenses wearing different codes.
        XCTAssertEqual(LensNameParser.parse("Noctilux-M 50mm f/0.95 ASPH")?.apertureX100, 95)
        XCTAssertEqual(LensNameParser.parse("Noctilux-M 50mm f/1")?.apertureX100, 100)
        XCTAssertEqual(SixBitTable.match(lensModel: "Noctilux-M 1:0.95/50 ASPH.")?.code, "110001")
        XCTAssertEqual(SixBitTable.match(lensModel: "Noctilux-M 1:1/50")?.code, "011111")
    }

    func testGenerationMarkersKeepDistinctCodesApart() {
        // The ASPH marker is the whole difference between these three codes.
        XCTAssertEqual(SixBitTable.match(lensModel: "Summicron-M 1:2/35 ASPH.")?.code, "011110")
        XCTAssertEqual(SixBitTable.match(lensModel: "Summicron-M 1:2/35")?.code, "000110")
        XCTAssertEqual(SixBitTable.match(lensModel: "APO-Summicron-M 1:2/35 ASPH.")?.code, "001101")
    }

    func testUnparseableReturnsNil() {
        XCTAssertNil(LensNameParser.parse("just words"))
        XCTAssertNil(LensNameParser.parse(""))
        XCTAssertNil(LensNameParser.key(of: "N/A"))
    }

    func testSixBitTableMatchesCameraString() {
        let match = SixBitTable.match(lensModel: "Summicron-M 1:2/28 ASPH.")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.code, "011010")
    }

    func testThirdPartyLensDoesNotMatchLeicaTable() {
        // Even when the specs line up with a Leica lens exactly, a third-party
        // name must never resolve to a code — that's what mappings are for.
        for name in ["Voigtlander VM 35mm f/2 Ultron Aspherical",
                     "Voigtlander VM 50mm f/1.5 Nokton Vintage Line",
                     "Zeiss Biogon T* 2/35 ZM",
                     "7Artisans 50mm f/1.1"] {
            XCTAssertNil(SixBitTable.match(lensModel: name), name)
            XCTAssertEqual(SixBitTable.matchCandidates(lensModel: name).count, 0, name)
        }
    }

    func testAmbiguousNameReportsItsCandidatesInsteadOfGuessing() {
        // Two Elmarit-M 28/2.8 generations wear different codes and the camera
        // writes no generation marker: candidates, not a guess.
        let candidates = SixBitTable.matchCandidates(lensModel: "Elmarit-M 1:2.8/28")
        XCTAssertEqual(Set(candidates.map(\.code)), ["000011", "011011"])
        XCTAssertNil(SixBitTable.match(lensModel: "Elmarit-M 1:2.8/28"))

        // A name that does carry the marker names one code.
        XCTAssertEqual(SixBitTable.match(lensModel: "Elmarit-M 28mm f/2.8 (IV)")?.code, "011011")
        XCTAssertEqual(SixBitTable.matchCandidates(lensModel: "Summicron-M 1:2/35 ASPH.").count, 1)
    }

    func testGenerationlessNameNeverSkipsTheAmbiguityCheck() {
        // A name without a generation marker must be answered from the base
        // group, so it can't slip past the check by hitting an exact row that
        // happens to carry no marker either.
        for name in ["Elmarit-M 28mm f/2.8", "Summicron-M 50mm f/2", "Summicron-M 1:2/50"] {
            XCTAssertNil(SixBitTable.match(lensModel: name), name)
            XCTAssertGreaterThan(SixBitTable.matchCandidates(lensModel: name).count, 1, name)
        }
    }

    func testRankedCodesSuggestMatchingSpecsFirst() {
        // A Voigtländer 35/2 should suggest a Leica 35mm f/2 code (a Summicron
        // 35) before anything else.
        let identity = LensNameParser.parse("Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertNotNil(identity)
        let first = SixBitTable.ranked(for: identity).first
        XCTAssertNotNil(first)
        let entries = SixBitTable.byCode[first!] ?? []
        XCTAssertTrue(entries.contains { $0.lensName.contains("35mm f/2") },
                      "expected a 35mm f/2 code first, got \(entries.map(\.lensName))")

        // Without an identity, table order is preserved.
        XCTAssertEqual(SixBitTable.ranked(for: nil), SixBitTable.uniqueCodes)
    }

    func testRankedOrdersSameFocalBeforeNearestAperture() {
        // Same focal always wins: every 50mm code, however far off in
        // aperture, ranks above codes for other focal lengths.
        let identity = LensNameParser.parse("Zeiss ZM 50mm f/1.5 Sonnar")
        let ranked = SixBitTable.ranked(for: identity)
        func isFifty(_ code: String) -> Bool {
            (SixBitTable.byCode[code] ?? []).contains { LensNameParser.parse($0.lensName)?.focalMM == 50 }
        }
        let fifties = ranked.filter(isFifty)
        XCTAssertGreaterThan(fifties.count, 5)
        XCTAssertEqual(Array(ranked.prefix(fifties.count)), fifties,
                       "every same-focal code should precede other focals")

        // Then nearest aperture: f/1.4 is the closest the table gets to f/1.5.
        let firstEntries = SixBitTable.byCode[ranked[0]] ?? []
        XCTAssertTrue(firstEntries.contains { $0.lensName.contains("50mm f/1.4") },
                      "expected a 50mm f/1.4 code first, got \(firstEntries.map(\.lensName))")
    }
}
