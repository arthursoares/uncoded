import XCTest
@testable import Uncoded

final class ScanSessionTests: XCTestCase {
    // MARK: - FrameFix

    /// A fix that landed with a warning is still a fix: the seal stays, and so
    /// does revert. Only the wording changes.
    func testAWarnedFixIsStillFixed() {
        let warned = FrameFix.fixed(warnings: ["the .bak no longer matches"])
        XCTAssertTrue(warned.isFixed)
        XCTAssertFalse(warned.isFailure)
        XCTAssertEqual(warned.warnings, ["the .bak no longer matches"])
        XCTAssertEqual(warned.message, "the .bak no longer matches")
    }

    func testACleanFixSaysNothing() {
        let clean = FrameFix.fixed(warnings: [])
        XCTAssertTrue(clean.isFixed)
        XCTAssertTrue(clean.warnings.isEmpty)
        XCTAssertNil(clean.message, "nothing to show beside the seal")
    }

    func testSeveralWarningsAreAllKept() {
        let warned = FrameFix.fixed(warnings: ["first", "second"])
        XCTAssertEqual(warned.warnings.count, 2)
        XCTAssertEqual(warned.message, "first\n\nsecond")
    }

    func testOnlyAFixCarriesWarnings() {
        XCTAssertTrue(FrameFix.failed("no").warnings.isEmpty)
        XCTAssertTrue(FrameFix.revertRefused("no").warnings.isEmpty)
        XCTAssertTrue(FrameFix.failed("boom").isFailure)
        XCTAssertFalse(FrameFix.failed("boom").isFixed)
        XCTAssertTrue(FrameFix.revertRefused("changed").isFixed,
                      "the bytes on disk are still ours")
    }
}
