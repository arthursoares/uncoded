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

    private func file(_ name: String, in folder: URL) -> ScannedDNG {
        ScannedDNG(
            url: folder.appendingPathComponent(name),
            meta: TIFFReader.LensMetadata(),
            codeCandidates: [])
    }

    private func result(_ files: [ScannedDNG], folderReadable: Bool = true) -> ScanSession.ScanResult {
        ScanSession.ScanResult(
            outcome: DNGScanner.Outcome(files: files, unreadable: 0,
                                        skippedSubfolders: 0, folderReadable: folderReadable))
    }

    @MainActor
    private func finishScan(_ session: ScanSession, folder: URL,
                            with result: ScanSession.ScanResult) async throws {
        let task = try XCTUnwrap(session.scan(folder) { _ in result })
        await task.value
    }

    @MainActor
    func testAssignmentWorkflowKeepsMarkedScopeAndIgnoresFilesOutsideResults() async throws {
        let folder = URL(fileURLWithPath: "/assignment", isDirectory: true)
        let first = file("first.dng", in: folder)
        let second = file("second.dng", in: folder)
        let missing = file("missing.dng", in: folder)
        let lens = UserLens(name: "35mm", make: "Example")
        let session = ScanSession()
        try await finishScan(session, folder: folder, with: result([first, second]))

        session.select([first.url, missing.url])
        session.assign(lens, to: [first.url, missing.url])

        XCTAssertEqual(session.selection, [first.url],
                       "assigning must keep the visible marked scope")
        XCTAssertTrue(session.overrides[first.url] === lens)
        XCTAssertNil(session.overrides[missing.url],
                     "a stale row must not create hidden assignment state")

        session.removeOverrides(for: [first.url, missing.url])
        XCTAssertEqual(session.selection, [first.url],
                       "removing an override must not silently change fix scope")
        XCTAssertTrue(session.overrides.isEmpty)

        session.toggleSelection(second.url)
        XCTAssertEqual(session.selection, [first.url, second.url])
        session.toggleSelection(missing.url)
        XCTAssertEqual(session.selection, [first.url, second.url])
        session.clearSelection()
        XCTAssertTrue(session.selection.isEmpty)
    }

    @MainActor
    func testBusyAndScanningGuardsPreserveTheActiveWorkflow() async throws {
        let folder = URL(fileURLWithPath: "/guarded", isDirectory: true)
        let frame = file("frame.dng", in: folder)
        let lens = UserLens(name: "50mm", make: "Example")
        let replacement = UserLens(name: "75mm", make: "Example")
        let session = ScanSession()
        try await finishScan(session, folder: folder, with: result([frame]))
        session.select([frame.url])
        session.assign(lens, to: [frame.url])

        session.busy = .fixing
        session.clearSelection()
        session.toggleSelection(frame.url)
        session.assign(replacement, to: [frame.url])
        session.removeOverrides(for: [frame.url])
        XCTAssertEqual(session.selection, [frame.url])
        XCTAssertTrue(session.overrides[frame.url] === lens)

        session.busy = nil
        let gate = ScanGate()
        let task = try XCTUnwrap(session.scan(folder) { _ in await gate.waitForResult() })
        await gate.waitUntilStarted()
        session.clearSelection()
        session.toggleSelection(frame.url)
        session.assign(replacement, to: [frame.url])
        session.removeOverrides(for: [frame.url])
        XCTAssertEqual(session.selection, [frame.url])
        XCTAssertTrue(session.overrides[frame.url] === lens)

        await gate.finish(with: result([frame]))
        await task.value
        XCTAssertEqual(session.selection, [frame.url])
        XCTAssertTrue(session.overrides[frame.url] === lens)
    }

    @MainActor
    func testSameFolderRescanRetainsOnlyStateForFilesThatStillExist() async throws {
        let folder = URL(fileURLWithPath: "/same-folder", isDirectory: true)
        let kept = file("kept.dng", in: folder)
        let removed = file("removed.dng", in: folder)
        let added = file("added.dng", in: folder)
        let lens = UserLens(name: "35mm", make: "Example")
        let session = ScanSession()
        try await finishScan(session, folder: folder, with: result([kept, removed]))
        session.select([kept.url, removed.url])
        session.assign(lens, to: [kept.url, removed.url])

        try await finishScan(session, folder: folder, with: result([kept, added]))

        XCTAssertEqual(session.selection, [kept.url])
        XCTAssertEqual(Set(session.overrides.keys), [kept.url])
        XCTAssertTrue(session.overrides[kept.url] === lens)
    }

    @MainActor
    func testUnreadableSameFolderPrunesStateButDifferentFolderResetsImmediately() async throws {
        let firstFolder = URL(fileURLWithPath: "/first-folder", isDirectory: true)
        let otherFolder = URL(fileURLWithPath: "/other-folder", isDirectory: true)
        let frame = file("frame.dng", in: firstFolder)
        let lens = UserLens(name: "35mm", make: "Example")
        let session = ScanSession()
        try await finishScan(session, folder: firstFolder, with: result([frame]))
        session.select([frame.url])
        session.assign(lens, to: [frame.url])

        try await finishScan(session, folder: firstFolder,
                             with: result([], folderReadable: false))
        XCTAssertTrue(session.selection.isEmpty)
        XCTAssertTrue(session.overrides.isEmpty)

        try await finishScan(session, folder: firstFolder, with: result([frame]))
        session.select([frame.url])
        session.assign(lens, to: [frame.url])
        let gate = ScanGate()
        let task = try XCTUnwrap(session.scan(otherFolder) { _ in await gate.waitForResult() })
        await gate.waitUntilStarted()
        XCTAssertTrue(session.selection.isEmpty)
        XCTAssertTrue(session.overrides.isEmpty)
        await gate.finish(with: result([]))
        await task.value
    }

    @MainActor
    func testLensDeletedDuringPendingSameFolderRescanCannotReturnAtCommit() async throws {
        let folder = URL(fileURLWithPath: "/pending-deletion", isDirectory: true)
        let frame = file("frame.dng", in: folder)
        let lens = UserLens(name: "35mm", make: "Example")
        let session = ScanSession()
        try await finishScan(session, folder: folder, with: result([frame]))
        session.select([frame.url])
        session.assign(lens, to: [frame.url])

        let gate = ScanGate()
        let task = try XCTUnwrap(session.scan(folder) { _ in await gate.waitForResult() })
        await gate.waitUntilStarted()
        NotificationCenter.default.post(name: .uncodedLensWillDelete,
                                        object: lens.persistentModelID)
        XCTAssertTrue(session.overrides.isEmpty)
        XCTAssertTrue(session.selection.isEmpty)

        await gate.finish(with: result([frame]))
        await task.value
        XCTAssertTrue(session.overrides.isEmpty,
                      "commit must not restore a deleted SwiftData object")
        XCTAssertTrue(session.selection.isEmpty)
    }

    @MainActor
    func testRepeatedSameFolderScanKeepsStateUntilNewestResultPrunesIt() async throws {
        let folder = URL(fileURLWithPath: "/repeated", isDirectory: true)
        let frame = file("frame.dng", in: folder)
        let lens = UserLens(name: "35mm", make: "Example")
        let session = ScanSession()
        try await finishScan(session, folder: folder, with: result([frame]))
        session.select([frame.url])
        session.assign(lens, to: [frame.url])
        let olderGate = ScanGate()
        let newerGate = ScanGate()

        let olderTask = try XCTUnwrap(session.scan(folder) { _ in await olderGate.waitForResult() })
        await olderGate.waitUntilStarted()
        let newerTask = try XCTUnwrap(session.scan(folder) { _ in await newerGate.waitForResult() })
        await newerGate.waitUntilStarted()

        await olderGate.finish(with: result([]))
        await olderTask.value
        XCTAssertEqual(session.selection, [frame.url])
        XCTAssertTrue(session.overrides[frame.url] === lens)
        XCTAssertTrue(session.scanning)

        await newerGate.finish(with: result([frame]))
        await newerTask.value
        XCTAssertEqual(session.selection, [frame.url])
        XCTAssertTrue(session.overrides[frame.url] === lens)
        XCTAssertFalse(session.scanning)
    }

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
