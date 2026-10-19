import XCTest
@testable import Uncoded

final class ReferenceLensImporterTests: XCTestCase {
    func testEntryPrefersTrimmedEXIFAndPreservesProfileFields() throws {
        var metadata = TIFFReader.LensMetadata()
        metadata.lensModel = "  Voigtlander VM 35mm f/2 Ultron  \n"
        metadata.auxLens = "Different XMP lens"
        metadata.lensMake = "  Voigtlander  "
        metadata.lensSpec = "35mm f/2"
        metadata.auxLensInfo = "50/1 50/1 14/10 14/10"
        metadata.profileName = " Adobe profile "
        metadata.profileFilename = " profile.lcp "
        metadata.profileDigest = " ABC123 "

        let entry = try ReferenceLensImporter.entry(from: metadata, filename: "one.dng")

        XCTAssertEqual(entry.name, "Voigtlander VM 35mm f/2 Ultron")
        XCTAssertEqual(entry.make, "Voigtlander")
        XCTAssertEqual(entry.focalLength, "35mm")
        XCTAssertEqual(entry.aperture, "f/2")
        XCTAssertEqual(entry.profileName, " Adobe profile ")
        XCTAssertEqual(entry.profileFilename, " profile.lcp ")
        XCTAssertEqual(entry.profileDigest, " ABC123 ")
        XCTAssertEqual(entry.sourceFilenames, ["one.dng"])
    }

    func testOversizedNameSpecsCannotTrapFallbackParser() throws {
        var metadata = TIFFReader.LensMetadata()
        metadata.lensModel = "Mystery 999999999999999999999999999999999mm f/2"

        let entry = try ReferenceLensImporter.entry(from: metadata, filename: "hostile.dng")

        XCTAssertEqual(entry.name, metadata.lensModel)
        XCTAssertEqual(entry.focalLength, "")
        XCTAssertEqual(entry.aperture, "")
    }

    func testBlankEXIFFallsBackToXMPWithoutInventingMake() throws {
        var metadata = TIFFReader.LensMetadata()
        metadata.lensModel = " \n "
        metadata.auxLens = "  Zeiss Biogon 35mm f/2  "
        metadata.lensMake = "\t"

        let entry = try ReferenceLensImporter.entry(from: metadata, filename: "xmp.dng")

        XCTAssertEqual(entry.name, "Zeiss Biogon 35mm f/2")
        XCTAssertEqual(entry.make, "")
        XCTAssertEqual(entry.focalLength, "35mm")
        XCTAssertEqual(entry.aperture, "f/2")
    }

    func testRationalXMPInfoSupportsExactPrimeSpecs() throws {
        var metadata = TIFFReader.LensMetadata()
        metadata.lensModel = "Voigtlander Nokton"
        metadata.auxLensInfo = "75/2 150/4 19/20 95/100"

        let entry = try ReferenceLensImporter.entry(from: metadata, filename: "rational.dng")

        XCTAssertEqual(entry.focalLength, "37.5mm")
        XCTAssertEqual(entry.aperture, "f/0.95")
    }

    func testZoomOrMalformedMetadataIsNotGuessedFromName() throws {
        var zoom = TIFFReader.LensMetadata()
        zoom.lensModel = "Some Zoom 16mm f/4"
        zoom.lensSpec = "16-21mm f/4"
        zoom.auxLensInfo = "16/1 21/1 4/1 4/1"
        let zoomEntry = try ReferenceLensImporter.entry(from: zoom, filename: "zoom.dng")
        XCTAssertEqual(zoomEntry.focalLength, "")
        XCTAssertEqual(zoomEntry.aperture, "")

        var malformed = TIFFReader.LensMetadata()
        malformed.lensModel = "Prime 50mm f/1.2"
        malformed.auxLensInfo = "50/0 50/0 12/10 12/10"
        let malformedEntry = try ReferenceLensImporter.entry(from: malformed, filename: "bad.dng")
        XCTAssertEqual(malformedEntry.focalLength, "")
        XCTAssertEqual(malformedEntry.aperture, "")
    }

    func testMissingNameThrowsActionableError() {
        var metadata = TIFFReader.LensMetadata()
        metadata.lensModel = " "
        metadata.auxLens = nil

        XCTAssertThrowsError(try ReferenceLensImporter.entry(from: metadata, filename: "empty.dng")) {
            XCTAssertTrue($0.localizedDescription.contains("LensModel"))
            XCTAssertTrue($0.localizedDescription.contains("aux:Lens"))
        }
    }

    func testReadGroupsIdenticalEntriesButKeepsConflictingVariants() throws {
        let folder = try temporaryFolder()
        let first = folder.appendingPathComponent("first.dng")
        let duplicate = folder.appendingPathComponent("duplicate.dng")
        let conflict = folder.appendingPathComponent("conflict.dng")
        try makeTIFF(name: "Shared Lens", make: "Maker", lensSpec: (35, 1, 35, 1, 2, 1, 2, 1),
                     profileDigest: "AAA").write(to: first)
        try makeTIFF(name: "Shared Lens", make: "Maker", lensSpec: (35, 1, 35, 1, 2, 1, 2, 1),
                     profileDigest: "AAA").write(to: duplicate)
        try makeTIFF(name: "Shared Lens", make: "Maker", lensSpec: (50, 1, 50, 1, 2, 1, 2, 1),
                     profileDigest: "BBB").write(to: conflict)

        let result = ReferenceLensImporter.read([first, duplicate, conflict])

        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.entries[0].sourceFilenames, ["first.dng", "duplicate.dng"])
        XCTAssertEqual(result.entries[0].focalLength, "35mm")
        XCTAssertEqual(result.entries[0].profileName, "Profile")
        XCTAssertEqual(result.entries[0].profileFilename, "Profile.lcp")
        XCTAssertEqual(result.entries[0].profileDigest, "AAA")
        XCTAssertEqual(result.entries[1].sourceFilenames, ["conflict.dng"])
        XCTAssertEqual(result.entries[1].focalLength, "50mm")
    }

    func testMalformedFileFailureDoesNotBlockValidFileAndFilesAreUnchanged() throws {
        let folder = try temporaryFolder()
        let valid = folder.appendingPathComponent("valid.dng")
        let corrupt = folder.appendingPathComponent("corrupt.dng")
        let validBytes = makeTIFF(name: "Good Lens", make: nil, lensSpec: nil, profileDigest: nil)
        let corruptBytes = Data("not a TIFF".utf8)
        try validBytes.write(to: valid)
        try corruptBytes.write(to: corrupt)

        let result = ReferenceLensImporter.read([corrupt, valid])

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].name, "Good Lens")
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].filename, "corrupt.dng")
        XCTAssertTrue(result.failures[0].message.contains("Not a TIFF/DNG file"))
        XCTAssertEqual(try Data(contentsOf: valid), validBytes)
        XCTAssertEqual(try Data(contentsOf: corrupt), corruptBytes)
    }

    func testUnreadableURLIsReportedPerFile() {
        let missing = URL(fileURLWithPath: "/tmp/uncoded-reference-importer-missing-file.dng")
        let result = ReferenceLensImporter.read([missing])
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].filename, missing.lastPathComponent)
        XCTAssertTrue(result.failures[0].message.contains("Could not import"))
    }

    // MARK: - Minimal TIFF fixture

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReferenceLensImporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8(value >> 8)])
    }

    private func u32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
              UInt8((value >> 16) & 0xff), UInt8(value >> 24)])
    }

    private func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        u16(tag) + u16(type) + u32(count) + u32(value)
    }

    private typealias Spec = (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32)

    private func makeTIFF(name: String, make: String?, lensSpec: Spec?, profileDigest: String?) -> Data {
        let nameData = Data(name.utf8) + Data([0])
        let makeData = make.map { Data($0.utf8) + Data([0]) }
        let xmpText = profileDigest.map {
            #"<rdf:Description crs:LensProfileName="Profile" crs:LensProfileFilename="Profile.lcp" crs:LensProfileDigest="\#($0)"/>"#
        }
        let xmpData = xmpText.map { Data($0.utf8) }

        let ifd0Count = (xmpData == nil ? 0 : 1) + 1
        let ifd0Offset = 8
        let ifd0Size = 2 + ifd0Count * 12 + 4
        let xmpOffset = ifd0Offset + ifd0Size
        let exifOffset = xmpOffset + (xmpData?.count ?? 0)
        let exifCount = 1 + (makeData == nil ? 0 : 1) + (lensSpec == nil ? 0 : 1)
        let exifSize = 2 + exifCount * 12 + 4
        let makeOffset = exifOffset + exifSize
        let nameOffset = makeOffset + (makeData?.count ?? 0)
        let specOffset = nameOffset + nameData.count

        var data = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
        data += u16(UInt16(ifd0Count))
        if let xmpData {
            data += entry(tag: 0x02BC, type: 1, count: UInt32(xmpData.count), value: UInt32(xmpOffset))
        }
        data += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOffset))
        data += u32(0)
        if let xmpData { data += xmpData }

        data += u16(UInt16(exifCount))
        if let lensSpec {
            data += entry(tag: 0xA432, type: 5, count: 4, value: UInt32(specOffset))
        }
        if let makeData {
            data += entry(tag: 0xA433, type: 2, count: UInt32(makeData.count), value: UInt32(makeOffset))
        }
        data += entry(tag: 0xA434, type: 2, count: UInt32(nameData.count), value: UInt32(nameOffset))
        data += u32(0)
        if let makeData { data += makeData }
        data += nameData
        if let lensSpec {
            for value in [lensSpec.0, lensSpec.1, lensSpec.2, lensSpec.3,
                          lensSpec.4, lensSpec.5, lensSpec.6, lensSpec.7] {
                data += u32(value)
            }
        }
        return data
    }
}
