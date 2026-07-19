import XCTest
@testable import Uncoded

final class TIFFWriterTests: XCTestCase {
    // Reuse the synthetic-TIFF builder shape from TIFFReaderTests.

    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        u16(tag) + u16(type) + u32(count) + u32(value)
    }

    /// Builds an M11-shaped little-endian TIFF: IFD0 (Make/Model/XMP/ExifIFD)
    /// and Exif IFD (LensMake, LensModel, LensSpec, FocalLength).
    private func makeTIFF(xmp xmpString: String) -> Data {
        let make = Data("Leica Camera AG".utf8) + Data([0])
        let model = Data("LEICA M11".utf8) + Data([0])
        let lensMake = Data("Leica Camera AG".utf8) + Data([0])
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])
        let xmp = Data(xmpString.utf8)

        let ifd0Offset = 8
        let ifd0Size = 2 + 4 * 12 + 4
        let makeOff = ifd0Offset + ifd0Size
        let modelOff = makeOff + make.count
        let xmpOff = modelOff + model.count
        let exifOff = xmpOff + xmp.count
        let exifSize = 2 + 4 * 12 + 4
        let lensMakeOff = exifOff + exifSize
        let lensModelOff = lensMakeOff + lensMake.count
        let specOff = lensModelOff + lensModel.count
        let focalOff = specOff + 32

        var data = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
        data += u16(4)
        data += entry(tag: 0x010F, type: 2, count: UInt32(make.count), value: UInt32(makeOff))
        data += entry(tag: 0x0110, type: 2, count: UInt32(model.count), value: UInt32(modelOff))
        data += entry(tag: 0x02BC, type: 1, count: UInt32(xmp.count), value: UInt32(xmpOff))
        data += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOff))
        data += u32(0)
        data += make + model + xmp

        data += u16(4)
        data += entry(tag: 0x920A, type: 5, count: 1, value: UInt32(focalOff))
        data += entry(tag: 0xA432, type: 5, count: 4, value: UInt32(specOff))
        data += entry(tag: 0xA433, type: 2, count: UInt32(lensMake.count), value: UInt32(lensMakeOff))
        data += entry(tag: 0xA434, type: 2, count: UInt32(lensModel.count), value: UInt32(lensModelOff))
        data += u32(0)
        data += lensMake + lensModel
        data += u32(35000) + u32(1000) + u32(35000) + u32(1000) + u32(2000) + u32(1000) + u32(2000) + u32(1000)
        data += u32(35000) + u32(1000)

        return data
    }

    private let sampleXMP = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" aux:Lens="Summicron-M 1:2/35 ASPH."/>
    </rdf:RDF></x:xmpmeta>
    <?xpacket end="w"?>
    """ + String(repeating: " ", count: 512)

    private var voigtlander: LensWrite {
        LensWrite(lensMake: "Voigtlander",
                  lensModel: "Voigtlander VM 35mm f/2 Ultron Aspherical",
                  focalMM: 35, apertureF: 2,
                  profileName: "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)",
                  profileFilename: "Leica Camera AG (Voigtlander VM 35mm f2 Ultron Aspherical) - RAW.lcp",
                  profileDigest: "03CBD374CCB89A292AD832BB830E440F")
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoded-test-\(UUID().uuidString).dng")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testWriteAndReadBack() throws {
        let url = try writeTemp(makeTIFF(xmp: sampleXMP))
        _ = try TIFFWriter.apply(voigtlander, to: url)

        let meta = try TIFFReader.read(url: url)
        XCTAssertEqual(meta.lensMake, "Voigtlander")
        XCTAssertEqual(meta.lensModel, "Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertEqual(meta.auxLens, "Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertEqual(meta.profileName, "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)")
        XCTAssertEqual(meta.profileDigest, "03CBD374CCB89A292AD832BB830E440F")
        XCTAssertEqual(meta.lensSpec, "35mm f/2")
        XCTAssertEqual(meta.cameraModel, "LEICA M11", "untouched fields must survive")
    }

    func testXMPGrowsIntoPaddingWithoutMovingFile() throws {
        // The sample XMP has 512 bytes of padding — the rewrite must fit and
        // the file must not grow by the packet's size (only lens strings that
        // outgrew their slots get appended).
        let original = makeTIFF(xmp: sampleXMP)
        let url = try writeTemp(original)
        _ = try TIFFWriter.apply(voigtlander, to: url)
        let after = try Data(contentsOf: url)
        XCTAssertLessThan(after.count - original.count, 300,
                          "XMP should be rewritten in place, not appended")
    }

    func testRevertRestoresByteIdenticalFile() throws {
        let original = makeTIFF(xmp: sampleXMP)
        let url = try writeTemp(original)
        let journal = try TIFFWriter.apply(voigtlander, to: url)
        XCTAssertNotEqual(try Data(contentsOf: url), original)

        try TIFFWriter.revert(journal)
        XCTAssertEqual(try Data(contentsOf: url), original, "revert must be byte-perfect")
    }

    func testDryRunTouchesNothing() throws {
        let original = makeTIFF(xmp: sampleXMP)
        let url = try writeTemp(original)
        let journal = try TIFFWriter.apply(voigtlander, to: url, dryRun: true)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(journal.patches.isEmpty)
    }

    func testMissingXMPCreatesPacketViaIFD0Rebuild() throws {
        // Build a file with no XMP tag at all.
        var noXMP = makeTIFF(xmp: sampleXMP)
        // Rebuild via writer path instead: easier to just test transform on a
        // real structural case — drop the XMP entry by building a 3-entry IFD0.
        let make = Data("Leica Camera AG".utf8) + Data([0])
        let model = Data("LEICA M11".utf8) + Data([0])
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])
        let ifd0Offset = 8
        let ifd0Size = 2 + 3 * 12 + 4
        let makeOff = ifd0Offset + ifd0Size
        let modelOff = makeOff + make.count
        let exifOff = modelOff + model.count
        let exifSize = 2 + 1 * 12 + 4
        let lensModelOff = exifOff + exifSize
        noXMP = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
        noXMP += u16(3)
        noXMP += entry(tag: 0x010F, type: 2, count: UInt32(make.count), value: UInt32(makeOff))
        noXMP += entry(tag: 0x0110, type: 2, count: UInt32(model.count), value: UInt32(modelOff))
        noXMP += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOff))
        noXMP += u32(0)
        noXMP += make + model
        noXMP += u16(1)
        noXMP += entry(tag: 0xA434, type: 2, count: UInt32(lensModel.count), value: UInt32(lensModelOff))
        noXMP += u32(0)
        noXMP += lensModel

        let url = try writeTemp(noXMP)
        var write = voigtlander
        write.focalMM = nil // this minimal file has no FocalLength/LensSpec…
        write.apertureF = nil
        _ = try TIFFWriter.apply(write, to: url)

        let meta = try TIFFReader.read(url: url)
        XCTAssertEqual(meta.auxLens, "Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertEqual(meta.profileName, "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)")
        XCTAssertEqual(meta.cameraModel, "LEICA M11")
        XCTAssertEqual(meta.lensModel, "Voigtlander VM 35mm f/2 Ultron Aspherical")
    }

    func testTransformXMPReplacesAndInserts() {
        let xmp = #"<rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" aux:Lens="Old Lens"/>"#
        let out = TIFFWriter.transformXMP(xmp, properties: [
            ("aux:Lens", "New Lens"),
            ("crs:LensProfileName", "Adobe (Profile)"),
        ])
        XCTAssertTrue(out.contains(#"aux:Lens="New Lens""#))
        XCTAssertFalse(out.contains("Old Lens"))
        XCTAssertTrue(out.contains(#"crs:LensProfileName="Adobe (Profile)""#))
        XCTAssertTrue(out.contains("xmlns:crs="), "missing namespace must be declared")
    }

    func testTransformXMPEscapesValues() {
        let out = TIFFWriter.transformXMP(#"<rdf:Description rdf:about=""/>"#,
                                          properties: [("aux:Lens", "A \"B\" & <C>")])
        XCTAssertTrue(out.contains("A &quot;B&quot; &amp; &lt;C&gt;"))
    }
}
