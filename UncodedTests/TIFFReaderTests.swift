import XCTest
@testable import Uncoded

final class TIFFReaderTests: XCTestCase {
    // MARK: - Synthetic little-endian DNG-like TIFF

    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32) -> Data {
        u16(tag) + u16(type) + u32(count) + u32(value)
    }

    /// Builds a minimal M11-shaped file: IFD0 with Make/Model/XMP/ExifIFD
    /// pointer, and an Exif IFD with LensModel.
    private func makeTIFF() -> Data {
        let make = Data("Leica Camera AG".utf8) + Data([0])
        let model = Data("LEICA M11".utf8) + Data([0])
        let lensModel = Data("Noctilux-M 1:1.2/50 ASPH.".utf8) + Data([0])
        let xmp = Data(#"""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF><rdf:Description
         aux:Lens="Noctilux-M 1:1.2/50 ASPH."
         crs:LensProfileName="Adobe (Leica Noctilux-M 50mm f/1.2 ASPH.)"
         crs:LensProfileDigest="ABCDEF0123456789"/></rdf:RDF></x:xmpmeta>
        """#.utf8)

        let ifd0Offset = 8
        let ifd0Size = 2 + 4 * 12 + 4 // count + entries + next-IFD pointer
        let makeOff = ifd0Offset + ifd0Size
        let modelOff = makeOff + make.count
        let xmpOff = modelOff + model.count
        let exifOff = xmpOff + xmp.count
        let exifSize = 2 + 1 * 12 + 4
        let lensModelOff = exifOff + exifSize

        var data = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))

        // IFD0 (tags must be ascending)
        data += u16(4)
        data += entry(tag: 0x010F, type: 2, count: UInt32(make.count), value: UInt32(makeOff))
        data += entry(tag: 0x0110, type: 2, count: UInt32(model.count), value: UInt32(modelOff))
        data += entry(tag: 0x02BC, type: 1, count: UInt32(xmp.count), value: UInt32(xmpOff))
        data += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOff))
        data += u32(0)

        data += make + model + xmp

        // Exif IFD
        data += u16(1)
        data += entry(tag: 0xA434, type: 2, count: UInt32(lensModel.count), value: UInt32(lensModelOff))
        data += u32(0)
        data += lensModel

        return data
    }

    func testReadsSyntheticLeicaDNG() throws {
        let meta = try TIFFReader(data: makeTIFF()).lensMetadata()
        XCTAssertEqual(meta.cameraMake, "Leica Camera AG")
        XCTAssertEqual(meta.cameraModel, "LEICA M11")
        XCTAssertEqual(meta.lensModel, "Noctilux-M 1:1.2/50 ASPH.")
        XCTAssertEqual(meta.auxLens, "Noctilux-M 1:1.2/50 ASPH.")
        XCTAssertEqual(meta.profileName, "Adobe (Leica Noctilux-M 50mm f/1.2 ASPH.)")
        XCTAssertEqual(meta.profileDigest, "ABCDEF0123456789")
    }

    func testRejectsNonTIFF() {
        XCTAssertThrowsError(try TIFFReader(data: Data("not a tiff at all".utf8)))
        XCTAssertThrowsError(try TIFFReader(data: Data()))
    }

    func testShortInlineValue() throws {
        // A 3-byte string fits inline in the 4-byte value field.
        let model = Data("M\u{0}".utf8)
        var data = Data("II".utf8) + u16(42) + u32(8)
        data += u16(1)
        var inline = model
        inline.append(contentsOf: [0, 0]) // pad the 4-byte field
        data += u16(0x0110) + u16(2) + u32(UInt32(model.count)) + inline
        data += u32(0)

        let meta = try TIFFReader(data: data).lensMetadata()
        XCTAssertEqual(meta.cameraModel, "M")
    }

    func testXMPElementForm() {
        let xmp = "<rdf:Description><aux:Lens>Some Lens</aux:Lens></rdf:Description>"
        XCTAssertEqual(TIFFReader.xmpValue(xmp, property: "aux:Lens"), "Some Lens")
    }

    // MARK: - Real files (runs only when UNCODED_TEST_DNG points at one)

    func testAgainstRealDNGIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["UNCODED_TEST_DNG"] else {
            throw XCTSkip("set UNCODED_TEST_DNG=/path/to/file.dng to run")
        }
        let meta = try TIFFReader.read(url: URL(fileURLWithPath: path))
        XCTAssertNotNil(meta.cameraMake)
        XCTAssertNotNil(meta.lensModel)
    }
}
