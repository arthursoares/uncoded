import SwiftData
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

        // Every profile carries the digest that goes into crs:LensProfileDigest.
        let hex = CharacterSet(charactersIn: "0123456789ABCDEF")
        for profile in profiles {
            XCTAssertEqual(profile.digest.count, 32, profile.url.lastPathComponent)
            XCTAssertTrue(profile.digest.unicodeScalars.allSatisfy(hex.contains),
                          "expected uppercase hex, got \(profile.digest)")
        }
    }

    func testDigestIsTheUppercaseMD5OfTheFile() throws {
        // Pinned against a digest Lightroom itself wrote, recorded in the
        // fix_6bit_exif CLI's lens table: this is the identity Adobe stamped
        // into the .lcp, so it has to match byte for byte.
        try XCTSkipUnless(LCPIndex.isAvailable, "no Adobe CameraRaw lens profiles on this machine")
        let ultron = LCPIndex.defaultRoot
            .appendingPathComponent("Voigtlander/Leica")
            .appendingPathComponent("Leica Camera AG (Voigtlander VM 35mm f2 Ultron Aspherical) - RAW.lcp")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ultron.path),
                          "the pinned Voigtlander profile is not installed here")
        XCTAssertEqual(LCPIndex.digest(of: ultron), "03CBD374CCB89A292AD832BB830E440F")
    }

    func testDigestOfAMissingFileIsNil() {
        XCTAssertNil(LCPIndex.digest(of: URL(fileURLWithPath: "/nonexistent/nope.lcp")))
    }

    // MARK: - Backfilling lenses saved before the digest existed

    /// An in-memory store, so the backfill is never exercised against the user's.
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: UserLens.self, CodeMapping.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func lens(_ name: String, digest: String = "") -> UserLens {
        // Adobe's filenames carry no "f/" — and a slash would make the backfill's
        // lastPathComponent lookup a different string.
        let filename = name.replacingOccurrences(of: "/", with: "")
        return UserLens(name: name, make: "Voigtlander", focalLength: "35.0mm", aperture: "f/2",
                        profileName: "Adobe (\(name))",
                        profileFilename: "Leica Camera AG (\(filename)) - RAW.lcp",
                        profileDigest: digest)
    }

    private func profile(filename: String, digest: String) -> LCPProfile {
        LCPProfile(url: URL(fileURLWithPath: "/tmp/profiles/\(filename)"), maker: "Voigtlander",
                   cameraMake: "Leica Camera AG", cameraModel: "M11",
                   lensPrettyName: "Voigtlander VM 35mm f/2 Ultron Aspherical",
                   profileName: "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)",
                   digest: digest)
    }

    func testBackfillFillsInMissingDigests() throws {
        let context = try makeContext()
        let stale = lens("Voigtlander VM 35mm f/2 Ultron Aspherical")
        let unknown = lens("Some Lens Adobe Never Profiled")
        let manual = UserLens(name: "Hand typed", make: "MS Optical")
        for lens in [stale, unknown, manual] { context.insert(lens) }
        try context.save()

        let repaired = try LensProfileBackfill.run(in: context, profiles: [
            profile(filename: stale.profileFilename, digest: "03CBD374CCB89A292AD832BB830E440F"),
        ])

        XCTAssertEqual(repaired, 1)
        XCTAssertEqual(stale.profileDigest, "03CBD374CCB89A292AD832BB830E440F")
        XCTAssertEqual(unknown.profileDigest, "", "no such profile here, nothing to fill in")
        XCTAssertEqual(manual.profileDigest, "", "a lens with no .lcp has no digest to find")
    }

    func testBackfillAdoptsTheDigestOfTheInstalledProfile() throws {
        // Camera Raw ships a revised .lcp under the same filename and a digest
        // that was right yesterday now names a file that no longer exists — the
        // same dead reference an empty digest is.
        let context = try makeContext()
        let stale = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "0BS0LETE")
        context.insert(stale)
        try context.save()

        let repaired = try LensProfileBackfill.run(in: context, profiles: [
            profile(filename: stale.profileFilename, digest: "03CBD374CCB89A292AD832BB830E440F"),
        ])
        XCTAssertEqual(repaired, 1)
        XCTAssertEqual(stale.profileDigest, "03CBD374CCB89A292AD832BB830E440F")
    }

    func testBackfillLeavesAMatchingDigestAlone() throws {
        let context = try makeContext()
        let good = lens("Voigtlander VM 35mm f/2 Ultron Aspherical",
                        digest: "03CBD374CCB89A292AD832BB830E440F")
        context.insert(good)
        try context.save()

        XCTAssertEqual(try LensProfileBackfill.run(in: context, profiles: [
            profile(filename: good.profileFilename, digest: "03CBD374CCB89A292AD832BB830E440F"),
        ]), 0, "nothing to repair, so nothing is written")
    }

    func testBackfillKeepsADigestWhoseProfileIsNotInstalledHere() throws {
        // The user's Lightroom may hold a profile this machine's index doesn't.
        let context = try makeContext()
        let lens = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "03CBD374CCB89A29")
        context.insert(lens)
        try context.save()

        XCTAssertEqual(try LensProfileBackfill.run(in: context, profiles: [
            profile(filename: "Something Else - RAW.lcp", digest: "AABBCC"),
        ]), 0)
        XCTAssertEqual(lens.profileDigest, "03CBD374CCB89A29")
    }

    func testBackfillIsANoOpWithNoProfilesIndexed() throws {
        let context = try makeContext()
        let stale = lens("Voigtlander VM 35mm f/2 Ultron Aspherical")
        context.insert(stale)
        try context.save()

        XCTAssertEqual(try LensProfileBackfill.run(in: context, profiles: []), 0)
        XCTAssertEqual(stale.profileDigest, "")
    }
}
