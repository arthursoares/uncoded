import XCTest
@testable import Uncoded

final class FixerTests: XCTestCase {
    private var tempDir: URL!
    private var store: JournalStore!
    private var fixer: Fixer!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("uncoded-fixer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = JournalStore(directory: tempDir.appendingPathComponent("journals"))
        fixer = Fixer(store: store)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Minimal TIFF with just the fields the writer needs.
    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private func makeTIFF() -> Data {
        let lensModel = Data("Summicron-M 1:2/35 ASPH.".utf8) + Data([0])
        // A well-formed packet: every prefix declared, and the padding on the
        // inside of the trailer where the XMP spec puts it.
        let packet = #"""
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""/>
        </rdf:RDF></x:xmpmeta>
        \#(String(repeating: " ", count: 600))<?xpacket end="w"?>
        """#
        let xmp = Data(packet.utf8)
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

    private var otherWrite: LensWrite {
        LensWrite(lensMake: "Zeiss", lensModel: "Zeiss ZM 35mm f/2 Biogon",
                  focalMM: nil, apertureF: nil,
                  profileName: "Adobe (Y)", profileFilename: "Y.lcp", profileDigest: "DEF")
    }

    private func journalFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    func testFixCreatesBakAndJournalAndRevertRestores() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        let outcome = try fixer.fix(file: file, with: write, keepBak: true)
        XCTAssertEqual(outcome.warnings, [])

        let bak = file.appendingPathExtension("bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bak.path))
        XCTAssertEqual(try Data(contentsOf: bak), original, ".bak must be the pre-fix file")
        XCTAssertNotEqual(try Data(contentsOf: file), original)
        XCTAssertNotNil(store.journal(for: file))

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original, "revert must be byte-perfect")
        XCTAssertNil(store.journal(for: file), "journal consumed by revert")
    }

    func testFixWithoutBak() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try fixer.fix(file: file, with: write, keepBak: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
        XCTAssertNotNil(store.journal(for: file))
    }

    func testExistingBakIsNeverOverwritten() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        try fixer.fix(file: file, with: write, keepBak: true)
        try fixer.revert(file: file)
        let outcome = try fixer.fix(file: file, with: write, keepBak: true)

        let bak = file.appendingPathExtension("bak")
        XCTAssertEqual(try Data(contentsOf: bak), original,
                       "second fix must not clobber the pristine backup")
        XCTAssertEqual(outcome.warnings, [],
                       "a .bak matching the pre-fix file needs no warning")
    }

    func testFixedPathsListsJournaledFiles() throws {
        let a = tempDir.appendingPathComponent("a.dng")
        let b = tempDir.appendingPathComponent("b.dng")
        try makeTIFF().write(to: a)
        try makeTIFF().write(to: b)

        XCTAssertTrue(store.fixedPaths().isEmpty)
        try fixer.fix(file: a, with: write, keepBak: false)
        XCTAssertEqual(store.fixedPaths(), [a.path])

        try fixer.revert(file: a)
        XCTAssertTrue(store.fixedPaths().isEmpty, "revert consumes the journal")
    }

    func testRevertWithoutJournalThrows() {
        let file = tempDir.appendingPathComponent("never-fixed.dng")
        XCTAssertThrowsError(try fixer.revert(file: file))
    }

    // MARK: - Stacked journals

    func testRevertDrainsStackedJournals() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        try fixer.fix(file: file, with: write, keepBak: false)
        try fixer.fix(file: file, with: otherWrite, keepBak: false)
        XCTAssertEqual(journalFiles().count, 2, "a re-fix stacks a second journal")

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "revert must undo both writes, not just the last one")
        XCTAssertTrue(journalFiles().isEmpty, "no journal may survive a full revert")
        XCTAssertTrue(store.fixedPaths().isEmpty, "a later scan must not re-seal the frame")
    }

    func testSecondRevertAfterDrainThrows() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try fixer.fix(file: file, with: write, keepBak: false)
        try fixer.fix(file: file, with: otherWrite, keepBak: false)
        try fixer.revert(file: file)
        XCTAssertThrowsError(try fixer.revert(file: file))
    }

    // MARK: - Journal safety

    func testJournalIsSavedBeforeTheWrite() throws {
        // The journal must exist while the file is still pristine: a crash
        // between the two leaves an undo record, not an orphaned rewrite.
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        let prepared = try TIFFWriter.prepare(write, to: file)
        XCTAssertEqual(try Data(contentsOf: file), original, "prepare must not touch the file")
        let record = try store.save(prepared.journal)
        XCTAssertFalse(record.journal.isCommitted, "a pre-write journal is pending")

        // The interrupted-before-commit case: the pending journal describes a
        // write that never landed, so the file is not fixed and it is pruned.
        XCTAssertTrue(store.fixedPaths().isEmpty)
        XCTAssertTrue(journalFiles().isEmpty, "an abandoned pending journal is pruned")

        // The interrupted-after-commit case: the same journal, now matching the
        // bytes on disk, counts as a fix and is finalized in passing.
        let second = try store.save(prepared.journal)
        try prepared.commit()
        XCTAssertEqual(store.fixedPaths(), [file.path])
        XCTAssertEqual(store.journal(for: file)?.journal.isCommitted, true)
        XCTAssertEqual(journalFiles().count, 1)
        XCTAssertEqual(second.url.lastPathComponent, journalFiles().first?.lastPathComponent)

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testUnwritableJournalDirectoryStillFixesWithWarning() throws {
        // A journal directory that cannot be created must not turn into "the
        // fix failed" — the write is what the user asked for.
        let blocker = tempDir.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let blockedFixer = Fixer(store: JournalStore(directory: blocker.appendingPathComponent("journals")))

        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        let outcome = try blockedFixer.fix(file: file, with: write, keepBak: false)
        XCTAssertNotEqual(try Data(contentsOf: file), original, "the fix must still land")
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("Revert is not available"),
                      "unexpected warning: \(outcome.warnings)")
    }

    func testWriteFailureRemovesTheBakItCreated() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        XCTAssertThrowsError(try fixer.fix(file: file, with: write, keepBak: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path),
                       "a full-size backup of a file we never modified is litter")
        XCTAssertTrue(journalFiles().isEmpty, "no undo record for a write that never happened")
    }

    func testForeignBakIsKeptWithAWarning() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        let bak = file.appendingPathExtension("bak")
        let foreign = Data("some other file entirely".utf8)
        try foreign.write(to: bak)

        let outcome = try fixer.fix(file: file, with: write, keepBak: true)
        XCTAssertEqual(try Data(contentsOf: bak), foreign, "an unknown .bak is never replaced")
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("photo.dng.bak"),
                      "unexpected warning: \(outcome.warnings)")
    }

    func testStaleOwnBakIsKeptWithAWarning() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        try fixer.fix(file: file, with: write, keepBak: true)

        // Something else edits the file between the two fixes (Lightroom
        // writing metadata back, say): our .bak no longer matches it.
        var edited = original
        // Inside the XMP packet's padding: the bytes differ, the structure holds.
        let padding = try XCTUnwrap(edited.range(of: Data(repeating: 0x20, count: 64)))
        edited[padding.lowerBound + 8] = 0x0A
        try edited.write(to: file)

        let outcome = try fixer.fix(file: file, with: otherWrite, keepBak: true)
        XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("bak")), original,
                       "the pristine copy is kept, not refreshed from edited bytes")
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("has changed since"),
                      "unexpected warning: \(outcome.warnings)")
    }

    func testSameSecondFixesOfSameNamedFilesKeepBothJournals() throws {
        let dirs = ["one", "two"].map { tempDir.appendingPathComponent($0, isDirectory: true) }
        var files: [URL] = []
        for dir in dirs {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("photo.dng")
            try makeTIFF().write(to: file)
            files.append(file)
        }

        for file in files { try fixer.fix(file: file, with: write, keepBak: false) }

        XCTAssertEqual(journalFiles().count, 2, "one journal per file, same name or not")
        XCTAssertEqual(store.fixedPaths(), Set(files.map(\.path)))
        for file in files { XCTAssertNotNil(store.journal(for: file)) }
    }

    func testCorruptJournalIsReportedAsCorruptNotAsNeverFixed() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ this is not a journal".utf8)
            .write(to: store.directory.appendingPathComponent("photo.dng-2026-01-01T00-00-00Z-x.json"))

        XCTAssertThrowsError(try fixer.revert(file: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unreadable"),
                          "unexpected error: \(error.localizedDescription)")
        }
    }

    // MARK: - Renamed files

    func testRenamedFixedFileIsFoundByContentAndRefusesASecondFix() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        try fixer.fix(file: file, with: write, keepBak: false)

        // Lightroom-style rename-on-import.
        let renamed = tempDir.appendingPathComponent("2026-07-26-0001.dng")
        try FileManager.default.moveItem(at: file, to: renamed)

        XCTAssertNil(store.index().records.first { $0.journal.filePath == renamed.path },
                     "no journal exists at the new path")
        XCTAssertNotNil(store.journalClaiming(renamed), "the journal still claims the content")

        XCTAssertThrowsError(try fixer.fix(file: renamed, with: otherWrite, keepBak: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("already fixed"),
                          "unexpected error: \(error.localizedDescription)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.appendingPathExtension("bak").path),
                       "no .bak may be made from already-fixed bytes")

        try fixer.revert(file: renamed)
        XCTAssertEqual(try Data(contentsOf: renamed), original, "revert follows the rename")
        XCTAssertTrue(journalFiles().isEmpty)
    }

    // MARK: - Format compatibility

    func testV1JournalStillDecodesAndReverts() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        let journal = try TIFFWriter.apply(write, to: file)

        // A v0.1.x journal: only the five original keys, no state.
        let legacy: [String: Any] = [
            "filePath": journal.filePath,
            "date": journal.date.timeIntervalSinceReferenceDate,
            "originalLength": journal.originalLength,
            "appendedBytes": journal.appendedBytes,
            "patches": journal.patches.map {
                ["offset": $0.offset,
                 "original": $0.original.base64EncodedString(),
                 "new": $0.new.base64EncodedString()]
            },
        ]
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacy)
            .write(to: store.directory.appendingPathComponent("photo.dng-legacy.json"))

        let decoded = store.journal(for: file)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded?.journal.isCommitted == true, "a v0.1 journal was written post-commit")
        XCTAssertEqual(decoded?.journal.fileName, "photo.dng")
        XCTAssertEqual(store.fixedPaths(), [file.path])

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
