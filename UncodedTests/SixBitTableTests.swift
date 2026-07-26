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

    /// Camera strings the table can't resolve: two generations of the same
    /// lens wear different codes and the camera writes no generation marker.
    private let ambiguousCameraNames: Set<String> = [
        "Elmarit-M 1:2.8/28", // (III) is 000011, (IV) is 011011
        "Summicron-M 1:2/50", // (III) is 010111, (IV) and (V) are 100001
    ]

    /// Every lens in the table must find its own code back from both naming
    /// formats — a lens resolving to a neighbour's code fixes photos as the
    /// wrong lens.
    func testEveryLensRowRoundTripsToItsOwnCode() {
        var checked = 0
        for row in SixBitTable.all where row.isLens {
            guard LensNameParser.key(of: row.lensName) != nil else {
                // The macro adapters carry no focal/aperture to match on.
                XCTAssertTrue(row.lensName.hasPrefix("Macro-Adapter"), row.lensName)
                continue
            }
            checked += 1

            XCTAssertEqual(SixBitTable.match(lensModel: row.lensName)?.code, row.code,
                           "catalog name \(row.lensName)")

            let camera = cameraFormat(row.lensName)
            if ambiguousCameraNames.contains(camera) {
                XCTAssertNil(SixBitTable.match(lensModel: camera),
                             "\(camera) spans two codes and must not guess")
            } else {
                XCTAssertEqual(SixBitTable.match(lensModel: camera)?.code, row.code,
                               "camera name \(camera) (from \(row.lensName))")
            }
        }
        XCTAssertEqual(checked, 60, "the table's lens rows, macro adapters aside")
    }

    func testPlaceholderRowsAreNotSelectableCodes() {
        XCTAssertEqual(SixBitTable.all.filter { !$0.isLens }.count, 14)
        for code in SixBitTable.uniqueCodes {
            XCTAssertFalse((SixBitTable.byCode[code] ?? []).isEmpty, code)
        }
        // 111011 is listed twice: as the Summilux 90mm and as a placeholder.
        XCTAssertTrue(SixBitTable.uniqueCodes.contains("111011"))
        XCTAssertFalse(SixBitTable.uniqueCodes.contains("111111"))
        XCTAssertNil(SixBitTable.match(lensModel: "N/A"))
    }

    /// Rewrites a catalog name the way the camera writes it: "Summicron-M 35mm
    /// f/2 ASPH (I)" -> "Summicron-M 1:2/35 ASPH.", generation marker dropped.
    private func cameraFormat(_ catalog: String) -> String {
        let pattern = #"([0-9.\-]+)\s*mm\s*f/([0-9.,]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: catalog, range: NSRange(catalog.startIndex..., in: catalog)),
              let full = Range(match.range, in: catalog),
              let focal = Range(match.range(at: 1), in: catalog),
              let aperture = Range(match.range(at: 2), in: catalog)
        else { return catalog }

        let family = catalog[catalog.startIndex..<full.lowerBound].trimmingCharacters(in: .whitespaces)
        let stop = catalog[aperture].replacingOccurrences(of: ",", with: ".")
        return "\(family) 1:\(stop)/\(catalog[focal])" + (catalog.contains("ASPH") ? " ASPH." : "")
    }

    func testBitsMatchCodeString() {
        let row = SixBitCode(code: "110100", lensName: "x", productCodes: [], leicaIndex: "")
        XCTAssertEqual(row.bits, [true, true, false, true, false, false])
    }
}
