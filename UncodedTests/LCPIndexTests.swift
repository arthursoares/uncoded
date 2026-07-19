import XCTest
@testable import Uncoded

final class LCPIndexTests: XCTestCase {
    func testIndexesLocalMMountProfiles() throws {
        try XCTSkipUnless(LCPIndex.isAvailable, "no Adobe CameraRaw lens profiles on this machine")

        let profiles = LCPIndex.indexMMount()
        XCTAssertFalse(profiles.isEmpty, "expected M-mount .lcp profiles under the Adobe folder")

        // Every indexed profile should have parsed a lens name.
        let named = profiles.filter { $0.lensPrettyName != nil }
        XCTAssertGreaterThan(named.count, 0)

        // M-mount profiles are made for Leica bodies.
        let leicaMade = profiles.filter { $0.cameraMake?.contains("Leica") == true }
        XCTAssertGreaterThan(leicaMade.count, 0)

        // The index is deduped per lens and excludes Leitz Phone profiles.
        let names = profiles.compactMap(\.lensPrettyName)
        XCTAssertEqual(names.count, Set(names).count, "expected one entry per lens")
        XCTAssertFalse(profiles.contains { $0.cameraModel?.localizedCaseInsensitiveContains("phone") == true })
    }
}
