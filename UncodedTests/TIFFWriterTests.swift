import XCTest
@testable import Uncoded

final class TIFFWriterTests: XCTestCase {
    // Reuse the synthetic-TIFF builder shape from TIFFReaderTests.

    private func u16(_ v: UInt16, _ bigEndian: Bool = false) -> Data {
        let b = [UInt8(v & 0xFF), UInt8(v >> 8)]
        return bigEndian ? Data(b.reversed()) : Data(b)
    }

    private func u32(_ v: UInt32, _ bigEndian: Bool = false) -> Data {
        let b = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        return bigEndian ? Data(b.reversed()) : Data(b)
    }

    private func entry(tag: UInt16, type: UInt16, count: UInt32, value: UInt32,
                       _ bigEndian: Bool = false) -> Data {
        u16(tag, bigEndian) + u16(type, bigEndian) + u32(count, bigEndian) + u32(value, bigEndian)
    }

    /// A built fixture plus the offsets tests need to poke at its structure.
    private struct Fixture {
        let data: Data
        let bigEndian: Bool
        let ifd0Offset = 8
        let exifIFDOffset: Int
        let xmpOffset: Int
        let xmpCount: Int

        /// Absolute offset of an entry's 4-byte value/offset field.
        func valueField(ifd: Int, index: Int) -> Int { ifd + 2 + index * 12 + 8 }
        /// Absolute offset of an entry's 2-byte type field.
        func typeField(ifd: Int, index: Int) -> Int { ifd + 2 + index * 12 + 2 }
    }

    /// Builds an M11-shaped TIFF: IFD0 (Make/Model/XMP/ExifIFD) and Exif IFD
    /// (FocalLength, LensSpec, LensMake, LensModel).
    private func makeTIFF(xmp xmpString: String, bigEndian: Bool = false) -> Fixture {
        makeTIFF(xmpData: Data(xmpString.utf8), bigEndian: bigEndian)
    }

    private func makeTIFF(xmpData xmp: Data, bigEndian be: Bool = false) -> Fixture {
        let make = Data("Leica Camera AG".utf8) + Data([0])
        let model = Data("LEICA M11".utf8) + Data([0])
        let lensMake = Data("Leica Camera AG".utf8) + Data([0])
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])

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

        var data = Data((be ? "MM" : "II").utf8) + u16(42, be) + u32(UInt32(ifd0Offset), be)
        data += u16(4, be)
        data += entry(tag: 0x010F, type: 2, count: UInt32(make.count), value: UInt32(makeOff), be)
        data += entry(tag: 0x0110, type: 2, count: UInt32(model.count), value: UInt32(modelOff), be)
        data += entry(tag: 0x02BC, type: 1, count: UInt32(xmp.count), value: UInt32(xmpOff), be)
        data += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOff), be)
        data += u32(0, be)
        data += make + model + xmp

        data += u16(4, be)
        data += entry(tag: 0x920A, type: 5, count: 1, value: UInt32(focalOff), be)
        data += entry(tag: 0xA432, type: 5, count: 4, value: UInt32(specOff), be)
        data += entry(tag: 0xA433, type: 2, count: UInt32(lensMake.count), value: UInt32(lensMakeOff), be)
        data += entry(tag: 0xA434, type: 2, count: UInt32(lensModel.count), value: UInt32(lensModelOff), be)
        data += u32(0, be)
        data += lensMake + lensModel
        for v in [35000, 1000, 35000, 1000, 2000, 1000, 2000, 1000] { data += u32(UInt32(v), be) }
        data += u32(35000, be) + u32(1000, be)

        return Fixture(data: data, bigEndian: be, exifIFDOffset: exifOff,
                       xmpOffset: xmpOff, xmpCount: xmp.count)
    }

    private let packet = """
    <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" aux:Lens="Summicron-M 1:2/35 ASPH."/>
    </rdf:RDF></x:xmpmeta>
    <?xpacket end="w"?>
    """

    /// Whitespace padding where the XMP spec puts it: after the XML, *before*
    /// the trailing `<?xpacket end?>` PI. (v0.1.x wrote it after the trailer,
    /// which put the padding outside the packet it was meant to pad.)
    private func padding(_ packet: String, _ count: Int) -> String {
        packet.replacingOccurrences(of: "<?xpacket end",
                                    with: String(repeating: " ", count: count) + "<?xpacket end")
    }

    private var sampleXMP: String { padding(packet, 512) }

    /// The XMP packet as it sits in a file on disk.
    private func xmpPacket(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let layout = try TIFFReader(data: data).structure()
        let entry = try XCTUnwrap(layout.ifd0[0x02BC], "file has no XMP tag")
        let offset = Int(try XCTUnwrap(TIFFReader.u32(data, at: entry.fieldOffset,
                                                     littleEndian: layout.littleEndian)))
        return try XCTUnwrap(String(data: data.subdata(in: offset..<(offset + entry.count)),
                                    encoding: .utf8))
    }

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

    /// Asserts the write is refused and the file is left exactly as it was.
    private func assertRefuses(_ data: Data, _ write: LensWrite? = nil,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ check: ((Error) -> Void)? = nil) throws {
        let url = try writeTemp(data)
        XCTAssertThrowsError(try TIFFWriter.apply(write ?? voigtlander, to: url),
                             file: file, line: line) { check?($0) }
        XCTAssertEqual(try Data(contentsOf: url), data,
                       "a refused write must not touch the file", file: file, line: line)
    }

    func testWriteAndReadBack() throws {
        let url = try writeTemp(makeTIFF(xmp: sampleXMP).data)
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

    func testBigEndianRoundTrip() throws {
        // "MM" files exercise the reader's and writer's byte-swapping branches.
        let original = makeTIFF(xmp: sampleXMP, bigEndian: true).data
        let url = try writeTemp(original)
        let journal = try TIFFWriter.apply(voigtlander, to: url)

        let after = try Data(contentsOf: url)
        XCTAssertEqual(after.prefix(2), Data("MM".utf8), "byte order must be preserved")

        let meta = try TIFFReader.read(url: url)
        XCTAssertEqual(meta.lensMake, "Voigtlander")
        XCTAssertEqual(meta.lensModel, "Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertEqual(meta.lensSpec, "35mm f/2")
        XCTAssertEqual(meta.auxLens, "Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertEqual(meta.cameraModel, "LEICA M11")

        try TIFFWriter.revert(journal)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testXMPGrowsIntoPaddingWithoutMovingFile() throws {
        // The sample XMP has 512 bytes of padding — the rewrite must fit and
        // the file must not grow by the packet's size (only lens strings that
        // outgrew their slots get appended).
        let original = makeTIFF(xmp: sampleXMP).data
        let url = try writeTemp(original)
        _ = try TIFFWriter.apply(voigtlander, to: url)
        let after = try Data(contentsOf: url)
        XCTAssertLessThan(after.count - original.count, 300,
                          "XMP should be rewritten in place, not appended")
    }

    func testXMPWithoutPaddingMovesToEOFAndRePointsEntry() throws {
        // No padding: the rewritten packet cannot fit, so it must be appended
        // at end-of-file and the IFD0 entry re-pointed at it.
        let fixture = makeTIFF(xmp: packet)
        let url = try writeTemp(fixture.data)
        let journal = try TIFFWriter.apply(voigtlander, to: url)
        let after = try Data(contentsOf: url)

        let entry = try XCTUnwrap(TIFFReader(data: after).structure().ifd0[0x02BC])
        let offset = Int(try XCTUnwrap(TIFFReader.u32(after, at: entry.fieldOffset, littleEndian: true)))
        XCTAssertGreaterThanOrEqual(offset, fixture.data.count, "packet must live past the old EOF")
        XCTAssertGreaterThan(entry.count, fixture.xmpCount)

        // A whole, well-formed packet at the new location — what Lightroom and
        // exiftool will read.
        let moved = after.subdata(in: offset..<(offset + entry.count))
        let text = try XCTUnwrap(String(data: moved, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("<?xpacket begin="))
        XCTAssertTrue(text.hasSuffix(#"<?xpacket end="w"?>"#))
        XCTAssertTrue(text.contains("</x:xmpmeta>"))
        XCTAssertNoThrow(try XMLDocument(data: moved, options: []))
        XCTAssertEqual(TIFFReader.xmpValue(text, property: "aux:Lens"),
                       "Voigtlander VM 35mm f/2 Ultron Aspherical")
        XCTAssertEqual(try TIFFReader.read(url: url).profileName,
                       "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)")

        // The old bytes are simply orphaned, not rewritten — nothing points there.
        XCTAssertEqual(after.subdata(in: fixture.xmpOffset..<(fixture.xmpOffset + fixture.xmpCount)),
                       fixture.data.subdata(in: fixture.xmpOffset..<(fixture.xmpOffset + fixture.xmpCount)))

        try TIFFWriter.revert(journal)
        XCTAssertEqual(try Data(contentsOf: url), fixture.data)
    }

    func testRevertRestoresByteIdenticalFile() throws {
        let original = makeTIFF(xmp: sampleXMP).data
        let url = try writeTemp(original)
        let journal = try TIFFWriter.apply(voigtlander, to: url)
        XCTAssertNotEqual(try Data(contentsOf: url), original)

        try TIFFWriter.revert(journal)
        XCTAssertEqual(try Data(contentsOf: url), original, "revert must be byte-perfect")
    }

    func testRevertRefusesWhenFileChangedSinceFix() throws {
        let original = makeTIFF(xmp: sampleXMP).data
        let url = try writeTemp(original)
        let journal = try TIFFWriter.apply(voigtlander, to: url)

        // Simulate Lightroom (or anything else) touching the file after the
        // fix: flip one byte inside a patched region.
        var tampered = try Data(contentsOf: url)
        let offset = journal.patches[0].offset
        tampered[offset] ^= 0xFF
        try tampered.write(to: url)

        XCTAssertThrowsError(try TIFFWriter.revert(journal)) { error in
            guard case TIFFWriteError.fileChangedSinceFix = error else {
                return XCTFail("expected fileChangedSinceFix, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: url), tampered,
                       "a refused revert must not touch the file")
    }

    func testRevertRefusesWhenFileLengthChanged() throws {
        let url = try writeTemp(makeTIFF(xmp: sampleXMP).data)
        let journal = try TIFFWriter.apply(voigtlander, to: url)

        var grown = try Data(contentsOf: url)
        grown.append(Data("extra".utf8))
        try grown.write(to: url)

        XCTAssertThrowsError(try TIFFWriter.revert(journal))
    }

    func testDryRunTouchesNothing() throws {
        let original = makeTIFF(xmp: sampleXMP).data
        let url = try writeTemp(original)
        let journal = try TIFFWriter.apply(voigtlander, to: url, dryRun: true)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(journal.patches.isEmpty)
    }

    func testMissingXMPCreatesPacketViaIFD0Rebuild() throws {
        // Build a file with no XMP tag at all.
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
        var noXMP = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
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

    // MARK: - Malformed input (the writer must throw, never trap or write)

    func testRefusesTruncatedFile() throws {
        let full = makeTIFF(xmp: sampleXMP).data
        try assertRefuses(full.prefix(20))                       // mid-IFD0
        try assertRefuses(full.prefix(8))                        // header only
        try assertRefuses(Data("II".utf8) + u16(42))             // no IFD pointer
    }

    func testRefusesStringValueOffsetBeyondEOF() throws {
        let fixture = makeTIFF(xmp: sampleXMP)
        var data = fixture.data
        // LensModel (entry 3 of the Exif IFD) points past end-of-file. A short
        // replacement takes the patch-in-place path, straight at that offset.
        let field = fixture.valueField(ifd: fixture.exifIFDOffset, index: 3)
        data.replaceSubrange(field..<(field + 4), with: u32(UInt32(data.count + 4096)))

        var write = voigtlander
        write.lensModel = "Ultron"
        try assertRefuses(data, write) { error in
            guard case TIFFWriteError.corruptStructure = error else {
                return XCTFail("expected corruptStructure, got \(error)")
            }
        }
    }

    func testRefusesRationalValueOffsetBeyondEOF() throws {
        let fixture = makeTIFF(xmp: sampleXMP)
        var data = fixture.data
        // LensSpecification (entry 1) — rationals are always written in place.
        let field = fixture.valueField(ifd: fixture.exifIFDOffset, index: 1)
        data.replaceSubrange(field..<(field + 4), with: u32(0xFFFF_0000))
        try assertRefuses(data)
    }

    func testRefusesValueRangeStraddlingEOF() throws {
        let fixture = makeTIFF(xmp: sampleXMP)
        var data = fixture.data
        // Offset inside the file but the XMP packet's length runs off the end.
        let field = fixture.valueField(ifd: fixture.ifd0Offset, index: 2)
        data.replaceSubrange(field..<(field + 4), with: u32(UInt32(data.count - 8)))
        try assertRefuses(data)
    }

    func testRefusesOverlappingPatches() throws {
        let fixture = makeTIFF(xmp: sampleXMP)
        var data = fixture.data
        // LensMake and LensModel pointed at the same bytes: patching both in
        // place would write garbage and leave an unrevertable journal.
        let makeField = fixture.valueField(ifd: fixture.exifIFDOffset, index: 2)
        let modelField = fixture.valueField(ifd: fixture.exifIFDOffset, index: 3)
        let shared = try XCTUnwrap(TIFFReader.u32(data, at: modelField, littleEndian: true))
        data.replaceSubrange(makeField..<(makeField + 4), with: u32(shared))

        var write = voigtlander
        write.lensMake = "CV"
        write.lensModel = "Ultron"
        try assertRefuses(data, write) { error in
            guard case TIFFWriteError.corruptStructure = error else {
                return XCTFail("expected corruptStructure, got \(error)")
            }
        }
    }

    func testRefusesIFDEndingAtEOF() throws {
        // An Exif IFD whose 4-byte next-IFD pointer is missing, and a missing
        // LensMake so the writer has to rebuild that IFD. The rebuild used to
        // read those absent bytes and trap; parseIFD now rejects the file
        // outright, and the rebuild's slice() is the second line of defence.
        let make = Data("Leica Camera AG".utf8) + Data([0])
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])
        let xmp = Data(sampleXMP.utf8)
        let ifd0Offset = 8
        let ifd0Size = 2 + 3 * 12 + 4
        let makeOff = ifd0Offset + ifd0Size
        let xmpOff = makeOff + make.count
        let lensModelOff = xmpOff + xmp.count
        let exifOff = lensModelOff + lensModel.count

        var data = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
        data += u16(3)
        data += entry(tag: 0x010F, type: 2, count: UInt32(make.count), value: UInt32(makeOff))
        data += entry(tag: 0x02BC, type: 1, count: UInt32(xmp.count), value: UInt32(xmpOff))
        data += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOff))
        data += u32(0)
        data += make + xmp + lensModel
        data += u16(1)
        data += entry(tag: 0xA434, type: 2, count: UInt32(lensModel.count), value: UInt32(lensModelOff))
        // …and no next-IFD pointer: the IFD ends exactly at EOF.

        var write = voigtlander
        write.focalMM = nil
        write.apertureF = nil
        try assertRefuses(data, write)
    }

    func testRefusesIFDThatCannotHoldMoreEntries() throws {
        // 65535 entries is a legal IFD; adding LensMake and LensModel to it
        // can't be expressed in the UInt16 entry count.
        let full = Int(UInt16.max)
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])
        let xmp = Data(sampleXMP.utf8)
        let ifd0Offset = 8
        let xmpOff = ifd0Offset + 2 + 2 * 12 + 4
        let lensModelOff = xmpOff + xmp.count
        let exifOff = lensModelOff + lensModel.count

        var data = Data("II".utf8) + u16(42) + u32(UInt32(ifd0Offset))
        data += u16(2)
        data += entry(tag: 0x02BC, type: 1, count: UInt32(xmp.count), value: UInt32(xmpOff))
        data += entry(tag: 0x8769, type: 4, count: 1, value: UInt32(exifOff))
        data += u32(0)
        data += xmp + lensModel
        data += u16(UInt16(full))
        // All the same tag: the rebuild copies raw entries, so the count is what
        // matters, and neither LensMake nor LensModel is among them.
        let filler = entry(tag: 0x1000, type: 1, count: 4, value: 0)
        data.reserveCapacity(data.count + full * 12 + 4)
        for _ in 0..<full { data += filler }
        data += u32(0)

        var write = voigtlander
        write.focalMM = nil
        write.apertureF = nil
        try assertRefuses(data, write) { error in
            guard case TIFFWriteError.corruptStructure = error else {
                return XCTFail("expected corruptStructure, got \(error)")
            }
        }
    }

    func testRevertRefusesMalformedJournal() throws {
        let original = makeTIFF(xmp: sampleXMP).data
        let url = try writeTemp(original)
        let good = try TIFFWriter.apply(voigtlander, to: url, dryRun: true)

        func journal(patches: [WritePatch], originalLength: Int = original.count,
                     appended: Int = 0) -> WriteJournal {
            WriteJournal(filePath: url.path, date: Date(), originalLength: originalLength,
                         patches: patches, appendedBytes: appended)
        }
        let sane = WritePatch(offset: 0, original: Data([1, 2]), new: original.prefix(2))

        // Numbers a journal should never hold: each used to trap in subdata or
        // in the UInt64 conversions.
        let malformed = [
            journal(patches: [WritePatch(offset: -8, original: Data([0, 0]), new: Data([0, 0]))]),
            journal(patches: [sane], originalLength: -1),
            journal(patches: [sane], appended: -1),
            journal(patches: [WritePatch(offset: original.count - 1, original: Data([0]),
                                        new: Data([0, 0, 0, 0]))]),
            journal(patches: [WritePatch(offset: 0, original: Data(), new: original.prefix(2))]),
        ]
        for bad in malformed {
            XCTAssertThrowsError(try TIFFWriter.revert(bad)) { error in
                guard case TIFFWriteError.fileChangedSinceFix = error else {
                    return XCTFail("expected fileChangedSinceFix, got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        XCTAssertFalse(good.patches.isEmpty, "the dry run should still have planned a real write")
    }

    // MARK: - Commit ordering

    func testJournalOrdersValueBytesBeforePointers() throws {
        // commit() writes the journal's patches in order, and the ordering is the
        // crash-safety invariant: no count or offset field may be written before
        // the bytes it describes.
        let fixture = makeTIFF(xmp: sampleXMP)
        let url = try writeTemp(fixture.data)
        let journal = try TIFFWriter.apply(voigtlander, to: url, dryRun: true)

        // A patch landing inside an IFD's entry array (or in the header) touches
        // a count/offset field; anything else is value bytes.
        let entryArrays = [fixture.ifd0Offset, fixture.exifIFDOffset].map { $0 + 2 ..< $0 + 2 + 4 * 12 }
        let isPointer = journal.patches.map { patch in
            patch.offset < 8 || entryArrays.contains { $0.contains(patch.offset) }
        }
        XCTAssertTrue(isPointer.contains(true), "fixture must exercise pointer patches")
        XCTAssertTrue(isPointer.contains(false), "fixture must exercise value patches")
        if let firstPointer = isPointer.firstIndex(of: true) {
            XCTAssertFalse(isPointer[firstPointer...].contains(false),
                           "value patches must all precede pointer patches: \(isPointer)")
        }
    }

    func testRefusesNonTextLensModel() throws {
        let fixture = makeTIFF(xmp: sampleXMP)
        var data = fixture.data
        // LensModel stored as UNDEFINED: we don't know what those bytes are,
        // so we don't overwrite them.
        let typeField = fixture.typeField(ifd: fixture.exifIFDOffset, index: 3)
        data.replaceSubrange(typeField..<(typeField + 2), with: u16(7))
        try assertRefuses(data) { error in
            guard case TIFFWriteError.nonTextTag(let tag, let type) = error else {
                return XCTFail("expected nonTextTag, got \(error)")
            }
            XCTAssertEqual(tag, 0xA434)
            XCTAssertEqual(type, 7)
        }
    }

    func testRefusesUndecodableXMP() throws {
        // A packet that isn't UTF-8: replacing it would throw away develop
        // settings, ratings and GPS.
        let bogus = Data([0xFF, 0xFE, 0x00, 0x3C, 0x00, 0x78, 0xC0, 0x80]) + Data(repeating: 0x20, count: 64)
        try assertRefuses(makeTIFF(xmpData: bogus).data) { error in
            guard case TIFFWriteError.undecodableXMP = error else {
                return XCTFail("expected undecodableXMP, got \(error)")
            }
        }
    }

    func testRefusesOutOfRangeFocalAndAperture() throws {
        let data = makeTIFF(xmp: sampleXMP).data
        for (focal, aperture) in [(-35.0, 2.0), (1e12, 2.0), (35.0, -2.0), (Double.nan, 2.0)] {
            var write = voigtlander
            write.focalMM = focal
            write.apertureF = aperture
            try assertRefuses(data, write) { error in
                guard case TIFFWriteError.invalidValue = error else {
                    return XCTFail("expected invalidValue, got \(error)")
                }
            }
        }
    }

    // MARK: - XMP transform

    /// Wraps rdf:Description bodies in a well-formed packet — every prefix an
    /// XMP packet uses has to be declared, or it isn't XML.
    private func wrap(_ descriptions: String) -> String {
        """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        \(descriptions)
        </rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    func testTransformXMPReplacesAndInserts() throws {
        let xmp = wrap(#"<rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" aux:Lens="Old Lens"/>"#)
        let out = try TIFFWriter.transformXMP(xmp, properties: [
            ("aux:Lens", "New Lens"),
            ("crs:LensProfileName", "Adobe (Profile)"),
        ])
        XCTAssertTrue(out.contains(#"aux:Lens="New Lens""#))
        XCTAssertFalse(out.contains("Old Lens"))
        XCTAssertTrue(out.contains(#"crs:LensProfileName="Adobe (Profile)""#))
        XCTAssertTrue(out.contains("xmlns:crs="), "missing namespace must be declared")
        XCTAssertNoThrow(try XMLDocument(data: Data(out.utf8), options: []))
    }

    func testTransformXMPEscapesValues() throws {
        let out = try TIFFWriter.transformXMP(wrap(#"<rdf:Description rdf:about=""/>"#),
                                              properties: [("aux:Lens", "A \"B\" & <C>")])
        XCTAssertTrue(out.contains("A &quot;B&quot; &amp; &lt;C&gt;"))
        let parsed = try XMLDocument(data: Data(out.utf8), options: [])
        XCTAssertTrue(parsed.xmlString.contains("&amp;"), "the escaped value must round-trip")
    }

    func testTransformXMPRefusesPacketWithoutDescription() throws {
        // Nowhere to put the properties: reporting success would mean an EXIF-only
        // fix with untouched XMP.
        let xmp = #"""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/></x:xmpmeta>
        """#
        XCTAssertThrowsError(try TIFFWriter.transformXMP(xmp, properties: [("aux:Lens", "L")])) { error in
            guard case TIFFWriteError.xmpMissingDescription = error else {
                return XCTFail("expected xmpMissingDescription, got \(error)")
            }
        }
        try assertRefuses(makeTIFF(xmp: padding(xmp, 512)).data)
    }

    func testTransformXMPRefusesMalformedXML() throws {
        // Not XML at all: the old regex transform happily "edited" text like this
        // and produced a packet no reader could parse.
        let broken = wrap(#"<rdf:Description rdf:about="" aux:Lens="unclosed>"#)
        XCTAssertThrowsError(try TIFFWriter.transformXMP(broken, properties: [("aux:Lens", "L")])) { error in
            guard case TIFFWriteError.malformedXMP = error else {
                return XCTFail("expected malformedXMP, got \(error)")
            }
        }
        try assertRefuses(makeTIFF(xmp: padding(broken, 512)).data)
    }

    func testTransformXMPLeavesOtherDescriptionsAndHistoryAlone() throws {
        // The regex transform replaced *every* occurrence: a crs:LensProfileName
        // recorded inside an xmpMM:History entry, or held by a second
        // rdf:Description, got rewritten along with the real one.
        let xmp = wrap(#"""
        <rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/" aux:Lens="Old Lens" crs:LensProfileName="Old Profile"/>
        <rdf:Description rdf:about="" xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmlns:stEvt="http://ns.adobe.com/xap/1.0/sType/ResourceEvent#">
         <xmpMM:History><rdf:Seq><rdf:li rdf:parseType="Resource">
          <stEvt:action>saved</stEvt:action>
          <stEvt:parameters>crs:LensProfileName="Old Profile"</stEvt:parameters>
         </rdf:li></rdf:Seq></xmpMM:History>
        </rdf:Description>
        """#)
        let out = try TIFFWriter.transformXMP(xmp, properties: [
            ("aux:Lens", "New Lens"),
            ("crs:LensProfileName", "New Profile"),
        ])
        XCTAssertTrue(out.contains(#"crs:LensProfileName="New Profile""#))
        XCTAssertTrue(out.contains(#"<stEvt:parameters>crs:LensProfileName="Old Profile"</stEvt:parameters>"#),
                      "the history entry is a record of the past, not a property to update")
        XCTAssertEqual(out.components(separatedBy: "New Profile").count - 1, 1,
                       "exactly one property may be written")
    }

    func testTransformXMPSurvivesMarkupInsideAttributeValues() throws {
        // `>` inside an attribute value used to end the tag as far as the regex
        // was concerned, so the insertion landed in the middle of a value.
        let xmp = wrap(#"<rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:title="a &gt; b" dc:rights="x &lt;y&gt; z"/>"#)
        let out = try TIFFWriter.transformXMP(xmp, properties: [("aux:Lens", "New Lens")])
        let parsed = try XMLDocument(data: Data(out.utf8), options: [])
        let description = try XCTUnwrap(parsed.rootElement()?.elements(forName: "rdf:RDF").first?
            .elements(forName: "rdf:Description").first)
        XCTAssertEqual(description.attribute(forName: "dc:title")?.stringValue, "a > b")
        XCTAssertEqual(description.attribute(forName: "aux:Lens")?.stringValue, "New Lens")
    }

    func testTransformXMPUpdatesElementFormInPlace() throws {
        // Real M11 files that have been through Lightroom hold aux:LensInfo as a
        // child element, not an attribute.
        let xmp = wrap(#"""
        <rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/">
         <aux:LensInfo>50/1 50/1 12/10 12/10</aux:LensInfo>
        </rdf:Description>
        """#)
        let out = try TIFFWriter.transformXMP(xmp, properties: [("aux:LensInfo", "35/1 35/1 2/1 2/1")])
        XCTAssertTrue(out.contains("<aux:LensInfo>35/1 35/1 2/1 2/1</aux:LensInfo>"))
        XCTAssertFalse(out.contains("12/10"))
        XCTAssertFalse(out.contains(#"aux:LensInfo=""#), "the element form must not be duplicated")
    }

    func testTransformXMPKeepsThePacketWrapperAndTrailingBytes() throws {
        // The M11 writes a NUL byte after the trailer; the packet's PIs and that
        // byte are not the parser's to reformat.
        let xmp = "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
            + #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>"#
            + "\n<?xpacket end=\"w\"?>\u{0}"
        let out = try TIFFWriter.transformXMP(xmp, properties: [("aux:Lens", "L")])
        XCTAssertTrue(out.hasPrefix("<?xpacket begin=\"\u{FEFF}\""))
        XCTAssertTrue(out.hasSuffix("<?xpacket end=\"w\"?>\u{0}"))
    }

    // MARK: - Padding placement

    func testPaddingGoesBeforeTheTrailer() throws {
        let url = try writeTemp(makeTIFF(xmp: sampleXMP).data)
        _ = try TIFFWriter.apply(voigtlander, to: url)

        let text = try xmpPacket(of: url)
        XCTAssertTrue(text.hasSuffix(#"<?xpacket end="w"?>"#),
                      "the trailer must stay last — padding belongs inside the packet")
        let trailer = try XCTUnwrap(text.range(of: #"<?xpacket end"#, options: .backwards))
        XCTAssertTrue(text[..<trailer.lowerBound].hasSuffix("   "), "expected padding before the trailer")
        XCTAssertNoThrow(try XMLDocument(data: Data(text.utf8), options: []))
    }

    // MARK: - aux:LensInfo and the crs:LensProfile block

    func testWritesXMPLensInfoAlongsideTheEXIFOne() throws {
        // exiftool's -LensInfo= populated both copies. Writing only the EXIF one
        // leaves the camera's aux:LensInfo — the borrowed Leica lens's aperture —
        // as what Lightroom shows.
        let withLensInfo = padding(wrap(#"""
        <rdf:Description rdf:about="" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" aux:Lens="Noctilux-M 1:1.2/50 ASPH.">
         <aux:LensInfo>50/1 50/1 12/10 12/10</aux:LensInfo>
        </rdf:Description>
        """#), 512)
        let url = try writeTemp(makeTIFF(xmp: withLensInfo).data)
        _ = try TIFFWriter.apply(voigtlander, to: url)

        let text = try xmpPacket(of: url)
        XCTAssertEqual(TIFFReader.xmpValue(text, property: "aux:LensInfo"), "35/1 35/1 2/1 2/1")
        XCTAssertFalse(text.contains("12/10"), "the borrowed lens's aperture must not survive")
        XCTAssertEqual(try TIFFReader.read(url: url).lensSpec, "35mm f/2")
    }

    func testInsertsXMPLensInfoWhenThePacketHasNone() throws {
        // Straight off the camera there is no aux:LensInfo at all.
        let url = try writeTemp(makeTIFF(xmp: sampleXMP).data)
        _ = try TIFFWriter.apply(voigtlander, to: url)
        XCTAssertEqual(TIFFReader.xmpValue(try xmpPacket(of: url), property: "aux:LensInfo"),
                       "35/1 35/1 2/1 2/1")
    }

    func testLensInfoUsesUnreducedRationalsForFractionalSpecs() throws {
        var write = voigtlander
        write.focalMM = 50
        write.apertureF = 1.2
        XCTAssertEqual(write.xmpLensInfo, "50/1 50/1 12/10 12/10")

        write.focalMM = nil
        XCTAssertNil(write.xmpLensInfo, "no focal length means nothing truthful to write")
    }

    func testWritesTheProfileDigest() throws {
        let url = try writeTemp(makeTIFF(xmp: sampleXMP).data)
        _ = try TIFFWriter.apply(voigtlander, to: url)
        XCTAssertEqual(try TIFFReader.read(url: url).profileDigest,
                       "03CBD374CCB89A292AD832BB830E440F")
    }

    func testNoProfileMeansNoCRSBlockAtAll() throws {
        // A hand-typed lens names no Adobe profile. LensProfileSetup="Custom"
        // beside an empty Digest/Filename/Name is a reference to nothing.
        var write = voigtlander
        write.profileName = ""
        write.profileFilename = ""
        write.profileDigest = ""
        XCTAssertFalse(write.hasProfile)

        let url = try writeTemp(makeTIFF(xmp: sampleXMP).data)
        _ = try TIFFWriter.apply(write, to: url)

        let text = try xmpPacket(of: url)
        XCTAssertFalse(text.contains("crs:LensProfile"), "expected no crs:LensProfile* at all")
        XCTAssertEqual(TIFFReader.xmpValue(text, property: "aux:Lens"),
                       "Voigtlander VM 35mm f/2 Ultron Aspherical",
                       "the lens name is still written")
    }

    func testEmptyProfileFieldsAreSkippedIndividually() throws {
        // A lens row from v0.1.x that could not be backfilled still has a name
        // and a filename: write those, and no empty digest next to them.
        var write = voigtlander
        write.profileDigest = ""
        let properties = TIFFWriter.xmpProperties(for: write)
        let names = properties.map(\.0)
        XCTAssertTrue(names.contains("crs:LensProfileName"))
        XCTAssertTrue(names.contains("crs:LensProfileSetup"))
        XCTAssertFalse(names.contains("crs:LensProfileDigest"))
        XCTAssertTrue(properties.allSatisfy { !$0.1.isEmpty })
    }

}
