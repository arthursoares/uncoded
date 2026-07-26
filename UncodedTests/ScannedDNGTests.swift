import XCTest
@testable import Uncoded

final class ScannedDNGTests: XCTestCase {
    private struct StubLens: Identifiable { let id: Int }

    /// A scanned frame whose LensModel could mean `codes`.
    private func frame(candidates codes: [String]) -> ScannedDNG {
        let rows = codes.map {
            SixBitCode(code: $0, lensName: "lens \($0)", productCodes: [], leicaIndex: "")
        }
        return ScannedDNG(url: URL(fileURLWithPath: "/tmp/L1000001.DNG"),
                          meta: .init(), codeCandidates: rows)
    }

    func testMappedCodeResolvesToItsLens() {
        let mapped = ["010111": StubLens(id: 1)]
        XCTAssertEqual(frame(candidates: ["010111"]).mappedLens { mapped[$0] }?.id, 1)
    }

    func testUnmappedCodeResolvesToNothing() {
        let mapped: [String: StubLens] = [:]
        XCTAssertNil(frame(candidates: ["010111"]).mappedLens { mapped[$0] })
    }

    func testOneLensClaimingBothCandidatesIsStillOneDestination() {
        // A re-coded lens wears both codes: old files carry one, new the other.
        let mapped = ["010111": StubLens(id: 7), "100001": StubLens(id: 7)]
        XCTAssertEqual(frame(candidates: ["010111", "100001"]).mappedLens { mapped[$0] }?.id, 7)
    }

    func testTwoLensesClaimingTheCandidatesStayUnresolved() {
        let mapped = ["010111": StubLens(id: 1), "100001": StubLens(id: 2)]
        XCTAssertNil(frame(candidates: ["010111", "100001"]).mappedLens { mapped[$0] })
    }

    func testTheSingleClaimedCandidateWins() {
        let mapped = ["100001": StubLens(id: 3)]
        XCTAssertEqual(frame(candidates: ["010111", "100001"]).mappedLens { mapped[$0] }?.id, 3)
    }

    func testMatchedCodeOnlyExistsWhenTheNameIsUnambiguous() {
        XCTAssertEqual(frame(candidates: ["010111"]).matchedCode?.code, "010111")
        XCTAssertNil(frame(candidates: ["010111", "100001"]).matchedCode)
        XCTAssertNil(frame(candidates: []).matchedCode)
    }
}
