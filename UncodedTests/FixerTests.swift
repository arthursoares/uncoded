import XCTest
@testable import Uncoded

final class FixerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoded-fixer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        JournalStore.overrideDirectory = tempDir.appendingPathComponent("journals")
    }

    override func tearDownWithError() throws {
        JournalStore.overrideDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Minimal TIFF with just the fields the writer needs.
    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private func makeTIFF() -> Data {
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])
        let xmp = Data((#"<rdf:Description rdf:about=""/>"# + String(repeating: " ", count: 600)).utf8)
        let ifd0Offset = 8
        let ifd0Size = 2 + 2 * 12 + 4
        let xmpOff = ifd0Offset + ifd0Size
        let exifOff = xmpOff + xmp.count
        let exifSize = 2 + 1 * 12 + 4
        let lensModelOff = exifOff + exifSize

        var data = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
        data += u16(2)
        data += u16(0x02BC) + u16(1) + u32(UInt32(xmp.count)) + u32(UInt32(xmpOff))
        data += u16(0x8769) + u16(4) + u32(1) + u32(UInt32(exifOff))
        data += u32(0)
        data += xmp
        data += u16(1)
        data += u16(0xA434) + u16(2) + u32(UInt32(lensModel.count)) + u32(UInt32(lensModelOff))
        data += u32(0)
        data += lensModel
        return data
    }

    private var write: LensWrite {
        LensWrite(lensMake: "Voigtlander", lensModel: "Voigtlander VM 35mm f/2 Ultron",
                  focalMM: nil, apertureF: nil,
                  profileName: "Adobe (X)", profileFilename: "X.lcp", profileDigest: "ABC")
    }

    func testFixCreatesBakAndJournalAndRevertRestores() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        try Fixer.fix(file: file, with: write, keepBak: true)

        let bak = file.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))
        XCTAssertEqual(try Data(contentsOf: bak), original, ".bak must be the pre-fix file")
        XCTAssertNotEqual(try Data(contentsOf: file), original)
        XCTAssertNotNil(JournalStore.journal(for: file))

        try Fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original, "revert must be byte-perfect")
        XCTAssertNil(JournalStore.journal(for: file), "journal consumed by revert")
    }

    func testFixWithoutBak() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try Fixer.fix(file: file, with: write, keepBak: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
        XCTAssertNotNil(JournalStore.journal(for: file))
    }

    func testExistingBakIsNeverOverwritten() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        try Fixer.fix(file: file, with: write, keepBak: true)
        try Fixer.revert(file: file)
        try Fixer.fix(file: file, with: write, keepBak: true)

        let bak = file.appendingPathExtension("bak")
        XCTAssertEqual(try Data(contentsOf: bak), original,
                       "second fix must not clobber the pristine backup")
    }

    func testRevertWithoutJournalThrows() {
        let file = tempDir.appendingPathComponent("never-fixed.dng")
        XCTAssertThrowsError(try Fixer.revert(file: file))
    }
}
