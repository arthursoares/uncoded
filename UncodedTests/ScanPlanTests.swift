import XCTest
@testable import Uncoded

final class ScanPlanTests: XCTestCase {
    @MainActor
    func testSelectedUnresolvedPhotoDoesNotFallBackToOtherPendingWrites() {
        let session = ScanSession()
        let unresolved = frame("unresolved")
        let pending = frame("pending")
        let lens = UserLens(name: "35mm lens", make: "Example")
        session.results = [unresolved, pending]
        session.assign(lens, to: [pending.url])
        session.select([unresolved.url])
        let plan = ScanView.ScanPlan(session: session, mappings: [], lenses: [lens])

        XCTAssertTrue(plan.primaryTargets(selection: session.selection, failuresOnly: false).isEmpty,
                      "The selected action must stay disabled, not fix the other photo")
        XCTAssertEqual(plan.primaryTargets(selection: [], failuresOnly: false).map(\.file.url),
                       [pending.url], "The other photo is available through explicit Fix All")
    }

    @MainActor
    func testAssignmentKeepsTheNextFixLimitedToTheSelectedPhotos() {
        let session = ScanSession()
        let selected = frame("selected")
        let other = frame("other")
        let lens = UserLens(name: "35mm lens", make: "Example")
        session.results = [selected, other]
        session.assign(lens, to: [other.url])
        session.select([selected.url])
        session.assign(lens, to: session.selection)
        let plan = ScanView.ScanPlan(session: session, mappings: [], lenses: [lens])

        XCTAssertEqual(plan.primaryTargets(selection: session.selection, failuresOnly: false).map(\.file.url),
                       [selected.url])
        XCTAssertEqual(plan.primaryTargets(selection: [], failuresOnly: false).count, 2)
    }

    @MainActor
    func testFailuresFilterExcludesHiddenPendingPhotosFromSelectionScope() {
        let session = ScanSession()
        let failed = frame("failed")
        let pending = frame("pending")
        let lens = UserLens(name: "35mm lens", make: "Example")
        session.results = [failed, pending]
        session.assign(lens, to: [failed.url, pending.url])
        session.fixState[failed.url] = .failed("Temporary write failure")
        let plan = ScanView.ScanPlan(session: session, mappings: [], lenses: [lens])

        XCTAssertEqual(plan.primaryTargets(selection: [], failuresOnly: true).map(\.file.url), [failed.url])
        XCTAssertTrue(plan.primaryTargets(selection: [pending.url], failuresOnly: true).isEmpty)
    }

    private func frame(_ name: String) -> ScannedDNG {
        ScannedDNG(url: URL(fileURLWithPath: "/scan-plan/\(name).dng"),
                   meta: TIFFReader.LensMetadata(), codeCandidates: [])
    }
}
