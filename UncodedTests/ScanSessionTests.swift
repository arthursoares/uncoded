import XCTest
@testable import Uncoded

final class ScanSessionTests: XCTestCase {
    private actor ScanGate {
        private var resultContinuation: CheckedContinuation<ScanSession.ScanResult, Never>?
        private var startContinuation: CheckedContinuation<Void, Never>?

        func waitForResult() async -> ScanSession.ScanResult {
            await withCheckedContinuation { continuation in
                resultContinuation = continuation
                startContinuation?.resume()
                startContinuation = nil
            }
        }

        func waitUntilStarted() async {
            guard resultContinuation == nil else { return }
            await withCheckedContinuation { startContinuation = $0 }
        }

        func finish(with result: ScanSession.ScanResult) {
            resultContinuation?.resume(returning: result)
            resultContinuation = nil
        }
    }

    // MARK: - FrameFix

    /// A fix that landed with a warning is still a fix: the seal stays, and so
    /// does revert. Only the wording changes.
    func testAWarnedFixIsStillFixed() {
        let warned = FrameFix.fixed(warnings: ["the .bak no longer matches"])
        XCTAssertTrue(warned.isFixed)
        XCTAssertFalse(warned.isFailure)
        XCTAssertEqual(warned.warnings, ["the .bak no longer matches"])
    }

    func testACleanFixHasNoWarnings() {
        let clean = FrameFix.fixed(warnings: [])
        XCTAssertTrue(clean.isFixed)
        XCTAssertTrue(clean.warnings.isEmpty)
    }

    func testSeveralWarningsAreAllKept() {
        let warned = FrameFix.fixed(warnings: ["first", "second"])
        XCTAssertEqual(warned.warnings.count, 2)
    }

    func testOnlyAFixCarriesWarnings() {
        XCTAssertTrue(FrameFix.failed("no").warnings.isEmpty)
        XCTAssertTrue(FrameFix.revertRefused("no").warnings.isEmpty)
        XCTAssertTrue(FrameFix.failed("boom").isFailure)
        XCTAssertFalse(FrameFix.failed("boom").isFixed)
        XCTAssertTrue(FrameFix.revertRefused("changed").isFixed,
                      "the bytes on disk are still ours")
    }

    // MARK: - Resolution

    /// A frame resolved from the file's own claim is not a manual override —
    /// the distinction is what keeps the "manual" tag honest.
    func testAClaimedResolutionIsNotAManualOne() {
        let lens = UserLens(name: "Voigtlander VM 35mm f/2 Ultron Aspherical",
                            make: "Voigtlander")
        let claimed = Resolution(lens: lens, isManual: false, isClaimed: true)
        XCTAssertFalse(claimed.isManual)
        XCTAssertTrue(claimed.isClaimed)
        XCTAssertFalse(Resolution(lens: lens, isManual: true).isClaimed,
                       "an override says nothing about what the file claims")
    }

    // MARK: - Scanning

    @MainActor
    func testOlderScanCannotOverwriteANewerScan() async throws {
        let firstURL = URL(fileURLWithPath: "/first", isDirectory: true)
        let secondURL = URL(fileURLWithPath: "/second", isDirectory: true)
        let firstFile = ScannedDNG(
            url: firstURL.appendingPathComponent("first.dng"),
            meta: TIFFReader.LensMetadata(),
            codeCandidates: [])
        let secondFile = ScannedDNG(
            url: secondURL.appendingPathComponent("second.dng"),
            meta: TIFFReader.LensMetadata(),
            codeCandidates: [])
        let firstResult = ScanSession.ScanResult(
            outcome: DNGScanner.Outcome(files: [firstFile], unreadable: 4,
                                        skippedSubfolders: 3, folderReadable: false))
        let secondResult = ScanSession.ScanResult(
            outcome: DNGScanner.Outcome(files: [secondFile], unreadable: 1,
                                        skippedSubfolders: 2, folderReadable: true),
            sealed: [secondFile.url],
            renamedFrom: [secondFile.url: "before-import.dng"])
        let firstGate = ScanGate()
        let secondGate = ScanGate()
        let session = ScanSession()

        let olderTask = try XCTUnwrap(session.scan(firstURL) { _ in
            await firstGate.waitForResult()
        })
        await firstGate.waitUntilStarted()

        let newerTask = try XCTUnwrap(session.scan(secondURL) { _ in
            await secondGate.waitForResult()
        })
        await secondGate.waitUntilStarted()

        await firstGate.finish(with: firstResult)
        await olderTask.value

        XCTAssertEqual(session.folder, secondURL)
        XCTAssertTrue(session.results.isEmpty)
        XCTAssertTrue(session.scanning, "the current scan is still running")

        await secondGate.finish(with: secondResult)
        await newerTask.value

        XCTAssertEqual(session.folder, secondURL)
        XCTAssertEqual(session.results.map(\.url), [secondFile.url])
        XCTAssertEqual(session.unreadableCount, 1)
        XCTAssertEqual(session.skippedSubfolders, 2)
        XCTAssertTrue(session.folderReadable)
        XCTAssertTrue(session.fixState[secondFile.url]?.isFixed == true)
        XCTAssertEqual(session.renamedFrom[secondFile.url], "before-import.dng")
        XCTAssertFalse(session.scanning)
    }
}
