import XCTest
@testable import Uncoded

final class UserLensTests: XCTestCase {
    private func lens(_ name: String, focal: String = "35.0mm", aperture: String = "f/2",
                      digest: String = "") -> UserLens {
        // Adobe's filenames have no "f/" in them — and a slash in a filename
        // would make the backfill's lastPathComponent lookup a different string.
        let filename = name.replacingOccurrences(of: "/", with: "")
        return UserLens(name: name, make: "Voigtlander", focalLength: focal, aperture: aperture,
                        profileName: "Adobe (\(name))",
                        profileFilename: "Leica Camera AG (\(filename)) - RAW.lcp",
                        profileDigest: digest)
    }

    // MARK: - lensWrite

    func testLensWriteParsesFocalAndAperture() {
        let write = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "ABC").lensWrite
        XCTAssertEqual(write.focalMM, 35)
        XCTAssertEqual(write.apertureF, 2)
        XCTAssertEqual(write.profileDigest, "ABC")
        XCTAssertTrue(write.hasProfile)
        XCTAssertEqual(write.xmpLensInfo, "35/1 35/1 2/1 2/1")
    }

    func testHandTypedLensNamesNoProfile() {
        let manual = UserLens(name: "MS Optical Sonnetar 50mm f/1.1", make: "MS Optical",
                              focalLength: "50.0mm", aperture: "f/1.1")
        let write = manual.lensWrite
        XCTAssertFalse(write.hasProfile, "nothing to put in crs:LensProfile*")
        XCTAssertEqual(write.xmpLensInfo, "50/1 50/1 11/10 11/10")
    }

    func testLensWriteWithUnparseableSpecsWritesNoLensInfo() {
        let odd = UserLens(name: "Mystery", make: "?", focalLength: "", aperture: "")
        XCTAssertNil(odd.lensWrite.xmpLensInfo)
    }

    // MARK: - Recognising Uncoded's own output

    func testClaimingMatchesTheUsersLensByName() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical")
        let other = lens("Voigtlander VM 50mm f/1.5 Nokton Vintage Line")
        let lenses = [other, mine]

        XCTAssertIdentical(UserLens.claiming(name: "Voigtlander VM 35mm f/2 Ultron Aspherical",
                                             in: lenses), mine)
        XCTAssertIdentical(UserLens.claiming(name: "  Voigtlander VM 35mm f/2 Ultron Aspherical  ",
                                             in: lenses), mine,
                           "a name is the same name with whitespace around it")
        XCTAssertIdentical(UserLens.claiming(name: "voigtlander vm 35mm f/2 ULTRON aspherical",
                                             in: lenses), mine)
    }

    func testClaimingIgnoresNamesThatAreNotTheUsersLenses() {
        let lenses = [lens("Voigtlander VM 35mm f/2 Ultron Aspherical")]
        XCTAssertNil(UserLens.claiming(name: "Summicron-M 1:2/35 ASPH.", in: lenses),
                     "an untouched Leica claim is for the code table to resolve")
        XCTAssertNil(UserLens.claiming(name: nil, in: lenses))
        XCTAssertNil(UserLens.claiming(name: "   ", in: lenses))
        XCTAssertNil(UserLens.claiming(name: "Voigtlander VM 35mm f/2 Ultron Aspherical", in: []))
    }

    func testClaimingReadsEXIFFirstThenXMP() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical")
        var meta = TIFFReader.LensMetadata()
        meta.lensModel = "Voigtlander VM 35mm f/2 Ultron Aspherical"
        XCTAssertIdentical(UserLens.claiming(meta, in: [mine]), mine)

        // A fix that landed in XMP but not in EXIF still names the lens.
        var xmpOnly = TIFFReader.LensMetadata()
        xmpOnly.lensModel = "Summicron-M 1:2/35 ASPH."
        xmpOnly.auxLens = "Voigtlander VM 35mm f/2 Ultron Aspherical"
        XCTAssertIdentical(UserLens.claiming(xmpOnly, in: [mine]), mine)

        XCTAssertNil(UserLens.claiming(TIFFReader.LensMetadata(), in: [mine]))
    }

    // MARK: - Would a re-fix write anything new?

    /// Everything a fix for `lens` would leave behind, as the reader sees it.
    private func fixedMetadata(_ lens: UserLens) -> TIFFReader.LensMetadata {
        var meta = TIFFReader.LensMetadata()
        meta.lensMake = lens.make
        meta.lensModel = lens.name
        meta.auxLens = lens.name
        meta.lensSpec = lens.lensWrite.lensSpecText
        meta.auxLensInfo = lens.lensWrite.xmpLensInfo
        meta.profileName = lens.profileName
        meta.profileFilename = lens.profileFilename
        meta.profileDigest = lens.profileDigest
        return meta
    }

    func testAFileAlreadyHoldingThisWriteNeedsNoRewrite() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "ABC")
        XCTAssertFalse(mine.lensWrite.differs(from: fixedMetadata(mine)))
    }

    func testAnUntouchedFrameDiffers() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "ABC")
        var camera = TIFFReader.LensMetadata()
        camera.lensMake = "Leica Camera AG"
        camera.lensModel = "Summicron-M 1:2/35 ASPH."
        XCTAssertTrue(mine.lensWrite.differs(from: camera))
    }

    /// The case the whole check exists for: v0.1.x wrote the name and left
    /// crs:LensProfileDigest empty, so the name alone says "nothing to do".
    func testAnEmptyProfileDigestOnDiskAsksForARewrite() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "ABC")
        var stale = fixedMetadata(mine)
        stale.profileDigest = ""
        XCTAssertTrue(mine.lensWrite.differs(from: stale))
        stale.profileDigest = nil
        XCTAssertTrue(mine.lensWrite.differs(from: stale))
    }

    func testAHalfLandedFixDiffers() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "ABC")
        var xmpOnly = fixedMetadata(mine)
        xmpOnly.lensModel = "Summicron-M 1:2/35 ASPH."
        XCTAssertTrue(xmpOnly.auxLens == mine.name)
        XCTAssertTrue(mine.lensWrite.differs(from: xmpOnly), "EXIF never got the write")
    }

    /// A hand-typed lens writes no crs:LensProfile* at all, so whatever the
    /// file already carries there is none of this write's business — otherwise
    /// the frame would ask to be rewritten forever.
    func testALensWithNoProfileIgnoresTheProfileFieldsOnDisk() {
        let manual = UserLens(name: "MS Optical Sonnetar 50mm f/1.1", make: "MS Optical",
                              focalLength: "50.0mm", aperture: "f/1.1")
        var meta = fixedMetadata(manual)
        meta.profileName = "Adobe (something else entirely)"
        meta.profileDigest = "ZZZ"
        XCTAssertFalse(manual.lensWrite.differs(from: meta))
    }

    /// A no-profile lens has no crs:LensProfile* to repair, so the wrong
    /// maximum aperture in the XMP twin is the whole of what a re-fix fixes —
    /// and v0.1.1 wrote only the EXIF copy, leaving this one saying f/2.
    func testANoProfileLensStillNoticesTheStaleLensInfo() {
        let manual = UserLens(name: "MS Optical Sonnetar 50mm f/1.1", make: "MS Optical",
                              focalLength: "50.0mm", aperture: "f/1.1")
        var v0 = fixedMetadata(manual)
        v0.auxLensInfo = "50/1 50/1 2/1 2/1" // the borrowed Leica lens's
        XCTAssertTrue(manual.lensWrite.differs(from: v0),
                      "this is the copy Lightroom shows")

        // And the EXIF side on its own.
        var exifOnly = fixedMetadata(manual)
        exifOnly.lensSpec = "50mm f/2"
        XCTAssertTrue(manual.lensWrite.differs(from: exifOnly))
    }

    /// A lens whose numbers can't be written is not a lens whose numbers
    /// disagree: with nothing to put in either field the write leaves both
    /// alone, so whatever they hold is none of its business.
    func testALensWithNoUsableNumbersLeavesTheSpecFieldsAlone() {
        let odd = UserLens(name: "Mystery", make: "?", focalLength: "", aperture: "")
        XCTAssertNil(odd.lensWrite.lensSpecText)
        XCTAssertNil(odd.lensWrite.xmpLensInfo)
        var meta = fixedMetadata(odd)
        meta.lensSpec = "50mm f/2"
        meta.auxLensInfo = "50/1 50/1 2/1 2/1"
        XCTAssertFalse(odd.lensWrite.differs(from: meta))
    }

    /// The writer stores every rational over 1000, so the comparison has to ask
    /// what lands on disk, not what was typed — or a fourth decimal place would
    /// leave the frame asking to be rewritten for ever.
    func testTheSpecComparisonUsesTheValueTheWriterWouldStore() {
        let odd = UserLens(name: "Odd", make: "?", focalLength: "35.0mm", aperture: "f/1.0625")
        XCTAssertEqual(odd.lensWrite.lensSpecText, "35mm f/1.063")
    }

    func testTrailingWhitespaceIsNotADifference() {
        let mine = lens("Voigtlander VM 35mm f/2 Ultron Aspherical", digest: "ABC")
        var padded = fixedMetadata(mine)
        padded.lensModel = " \(mine.name)\n"
        XCTAssertFalse(mine.lensWrite.differs(from: padded))
    }
}
