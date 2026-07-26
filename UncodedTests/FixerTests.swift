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

    /// `frame` stands in for image data: bytes no IFD points at, unique per
    /// frame, which is what the journal's content sample is taken from.
    private func makeTIFF(frame: UInt8 = 1) -> Data {
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
        data += Data((0..<4096).map { UInt8(($0 &* 31 &+ Int(frame)) & 0xFF) })
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

    func testJournalIsSavedBeforeTheWriteAndReadsNeverPruneIt() throws {
        // The journal must exist while the file is still pristine: a crash
        // between the two leaves an undo record, not an orphaned rewrite. And
        // in that window the record looks exactly like one for a write that
        // never happened — a scan running concurrently must not delete it.
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        let prepared = try TIFFWriter.prepare(write, to: file)
        XCTAssertEqual(try Data(contentsOf: file), original, "prepare must not touch the file")
        let record = try store.save(prepared.journal)
        XCTAssertFalse(record.journal.isCommitted, "a pre-write journal is pending")

        XCTAssertTrue(store.fixedPaths().isEmpty, "the write hasn't landed, so no seal")
        XCTAssertEqual(journalFiles().count, 1, "a read path must never delete a journal")

        // The interrupted-after-commit case: the same journal, now matching the
        // bytes on disk, counts as a fix and is finalized in passing.
        try prepared.commit()
        XCTAssertEqual(store.fixedPaths(), [file.path])
        XCTAssertEqual(store.journal(for: file)?.journal.isCommitted, true)
        XCTAssertEqual(journalFiles().count, 1)

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAbandonedJournalIsPrunedByTheNextFix() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        // A fix that died before its commit.
        _ = try store.save(try TIFFWriter.prepare(write, to: file).journal)

        try fixer.fix(file: file, with: write, keepBak: false)
        XCTAssertEqual(journalFiles().count, 1, "the dead record is pruned by the mutation path")

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(journalFiles().isEmpty)
    }

    func testUnwritableJournalDirectoryAbortsBeforeWriting() throws {
        // No undo record means no way back, and the file has not been touched
        // yet — so this must fail loudly instead of quietly rewriting the DNG.
        let blocker = tempDir.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let blockedFixer = Fixer(store: JournalStore(directory: blocker.appendingPathComponent("journals")))

        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)

        XCTAssertThrowsError(try blockedFixer.fix(file: file, with: write, keepBak: true)) { error in
            XCTAssertTrue(error.localizedDescription.contains("undo record"),
                          "unexpected error: \(error.localizedDescription)")
        }
        XCTAssertEqual(try Data(contentsOf: file), original, "nothing may be written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path),
                       "the abandoned fix takes its backup copy with it")
    }

    // MARK: - Interrupted commits

    /// A commit that died between writing its appendix and writing its patches:
    /// the file is its unfixed self with dead bytes glued on.
    private func simulateInterruptedAppendix(_ file: URL) throws -> JournalRecord {
        let prepared = try TIFFWriter.prepare(write, to: file)
        XCTAssertGreaterThan(prepared.journal.appendedBytes, 0, "fixture must append")
        let record = try store.save(prepared.journal)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: prepared.journal.appendedBytes))
        try handle.close()
        return record
    }

    func testAppendixWithoutPatchesIsNotAFix() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        let record = try simulateInterruptedAppendix(file)

        XCTAssertEqual(store.resolve(record), .abandonedWithAppendix)
        XCTAssertTrue(store.fixedPaths().isEmpty, "an unfixed file must not read as fixed")
        XCTAssertEqual(journalFiles().count, 1, "and the read path must not delete the record")
    }

    func testInterruptedAppendixIsRecoveredByTheNextFix() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        _ = try simulateInterruptedAppendix(file)

        try fixer.fix(file: file, with: write, keepBak: false)
        XCTAssertEqual(journalFiles().count, 1, "the dead record is gone, the new one is not")

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "the dead appendix must not survive as trailing junk")
    }

    /// A commit that died *inside* its first write — a full disk part way through
    /// the appendix. The file is its unfixed self plus a fragment.
    private func simulatePartialAppendix(_ file: URL) throws -> JournalRecord {
        let prepared = try TIFFWriter.prepare(write, to: file)
        XCTAssertGreaterThan(prepared.journal.appendedBytes, 1, "fixture must append")
        let record = try store.save(prepared.journal)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: prepared.journal.appendedBytes / 2))
        try handle.close()
        return record
    }

    func testPartiallyWrittenAppendixIsNotAFixAndIsRecovered() throws {
        // The length lands strictly between originalLength and writtenLength with
        // every patch still pre-write. That used to resolve `unverified`: the
        // frame sealed as maybe-fixed, recovery skipped it, and revert refused it
        // on its length check — no way back from a write that never touched a
        // single metadata field.
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        let record = try simulatePartialAppendix(file)

        let length = try Data(contentsOf: file).count
        XCTAssertGreaterThan(length, record.journal.originalLength)
        XCTAssertLessThan(length, record.journal.writtenLength, "fixture must be a partial appendix")

        XCTAssertEqual(store.resolve(record), .abandonedWithAppendix)
        XCTAssertTrue(store.resolve(record).isRecoverable)
        XCTAssertTrue(store.fixedPaths().isEmpty, "an unfixed file must not read as fixed")
        XCTAssertTrue(store.sealedURLs(in: [file]).sealed.isEmpty, "and must not be sealed")
        XCTAssertEqual(journalFiles().count, 1, "the read path must not delete the record")

        try fixer.fix(file: file, with: write, keepBak: false)
        XCTAssertEqual(journalFiles().count, 1, "the dead record is gone, the new one is not")

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "the fragment must not survive as trailing junk")
    }

    func testPartiallyWrittenAppendixIsRecoveredByRevert() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        _ = try simulatePartialAppendix(file)

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(journalFiles().isEmpty)
    }

    func testAnEditedFileAtAPartialAppendixLengthIsRefused() throws {
        // Same length, but a patched region holds bytes from neither state: not
        // our half-written file, and not ours to roll back.
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        let record = try simulatePartialAppendix(file)

        var edited = try Data(contentsOf: file)
        edited[record.journal.patches[0].offset] ^= 0xFF
        try edited.write(to: file)

        XCTAssertEqual(store.resolve(record), .unverified)
        XCTAssertThrowsError(try fixer.revert(file: file))
        XCTAssertEqual(try Data(contentsOf: file), edited, "a refused revert touches nothing")
    }

    // MARK: - Self-healing profile digest

    func testFixResolvesAnEmptyDigestFromTheInstalledProfile() throws {
        // LensProfileBackfill runs detached at launch, so a fix started seconds
        // later can still hold a v0.1.x lens row with no digest — and would write
        // the unresolvable profile reference the backfill exists to prevent.
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)

        var stale = write
        stale.profileDigest = ""
        stale.profileFilename = "Leica Camera AG (Voigtlander VM 35mm f2 Ultron) - RAW.lcp"

        var asked: [String] = []
        let healing = Fixer(store: store, profileDigest: { filename in
            asked.append(filename)
            return filename == stale.profileFilename ? "03CBD374CCB89A292AD832BB830E440F" : nil
        })
        try healing.fix(file: file, with: stale, keepBak: false)

        XCTAssertEqual(asked, [stale.profileFilename])
        XCTAssertEqual(try TIFFReader.read(url: file).profileDigest,
                       "03CBD374CCB89A292AD832BB830E440F",
                       "the written packet must carry the installed profile's digest")
    }

    func testFixLeavesADigestTheLensAlreadyHasAlone() throws {
        // A digest that disagrees with the installed file is the backfill's
        // business; writing something other than what the UI shows would be worse.
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)

        var asked = false
        let healing = Fixer(store: store, profileDigest: { _ in
            asked = true
            return "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        })
        try healing.fix(file: file, with: write, keepBak: false)

        XCTAssertFalse(asked, "a lens that has a digest is not looked up")
        XCTAssertEqual(try TIFFReader.read(url: file).profileDigest, write.profileDigest)
    }

    func testFixWithNoInstalledProfileWritesNoDigest() throws {
        // Nothing to heal with: the write goes ahead without a digest rather than
        // inventing one, and skips the crs block entirely.
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)

        var bare = write
        bare.profileDigest = ""
        bare.profileFilename = ""
        bare.profileName = ""

        let healing = Fixer(store: store, profileDigest: { _ in
            XCTFail("a lens with no .lcp filename has nothing to look up")
            return nil
        })
        try healing.fix(file: file, with: bare, keepBak: false)
        XCTAssertNil(try TIFFReader.read(url: file).profileDigest)
    }

    /// A commit that died part way through its patch loop: appendix written,
    /// then the first `applied` patches, then nothing.
    private func simulateInterruptedPatches(_ file: URL, applying applied: Int) throws -> JournalRecord {
        let prepared = try TIFFWriter.prepare(write, to: file)
        XCTAssertGreaterThan(prepared.journal.patches.count, applied,
                             "fixture must have more patches than we apply")
        let record = try store.save(prepared.journal)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: prepared.journal.appendedBytes))
        for patch in prepared.journal.patches.prefix(applied) {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.new)
        }
        try handle.close()
        return record
    }

    func testHalfWrittenPatchesAreNotAFixAndAreRecovered() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        let record = try simulateInterruptedPatches(file, applying: 1)

        XCTAssertEqual(store.resolve(record), .interrupted)
        XCTAssertTrue(store.fixedPaths().isEmpty, "a half-written file must not read as fixed")
        XCTAssertEqual(journalFiles().count, 1, "and the read path must not delete the record")

        try fixer.fix(file: file, with: write, keepBak: false)
        XCTAssertEqual(journalFiles().count, 1)
        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original,
                       "the half-written bytes must be rolled back, not built on")
    }

    func testHalfWrittenPatchesAreRecoveredByRevert() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        _ = try simulateInterruptedPatches(file, applying: 1)

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(journalFiles().isEmpty)
    }

    func testAFileEditedAfterAHalfWrittenFixIsRefused() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        let record = try simulateInterruptedPatches(file, applying: 1)

        // Something else writes inside a patched region: bytes from neither
        // state, so nothing here may be forced back.
        let patch = record.journal.patches[record.journal.patches.count - 1]
        let foreign = (UInt8(0)...UInt8(255)).first {
            $0 != patch.original.first! && $0 != patch.new.first!
        }!
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(patch.offset))
        try handle.write(contentsOf: Data([foreign]))
        try handle.close()
        let edited = try Data(contentsOf: file)

        XCTAssertEqual(store.resolve(record), .unverified)
        XCTAssertEqual(store.fixedPaths(), [file.path], "unknown state keeps revert reachable")
        XCTAssertThrowsError(try fixer.revert(file: file))
        XCTAssertEqual(try Data(contentsOf: file), edited, "a file we didn't make must not be forced")
    }

    func testInterruptedAppendixIsRecoveredByRevert() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        _ = try simulateInterruptedAppendix(file)

        try fixer.revert(file: file)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertTrue(journalFiles().isEmpty)
    }

    // MARK: - Copies and twins

    func testRevertOfACopyDoesNotConsumeTheOriginalsJournal() throws {
        let a = tempDir.appendingPathComponent("a.dng")
        let original = makeTIFF()
        try original.write(to: a)
        try fixer.fix(file: a, with: write, keepBak: false)

        // A copy of the fixed file: same content, no journal of its own.
        let b = tempDir.appendingPathComponent("b.dng")
        try FileManager.default.copyItem(at: a, to: b)

        XCTAssertThrowsError(try fixer.revert(file: b)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("a.dng") && message.contains("b.dng"),
                          "the error must name both files: \(message)")
        }
        XCTAssertEqual(journalFiles().count, 1, "the original's undo record survives")
        XCTAssertEqual(store.fixedPaths(), [a.path])

        XCTAssertThrowsError(try fixer.fix(file: b, with: otherWrite, keepBak: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("is a copy of"),
                          "a still-present original is a copy, not a rename: \(error.localizedDescription)")
        }

        try fixer.revert(file: a)
        XCTAssertEqual(try Data(contentsOf: a), original)
    }

    func testRefixPrefersThisFilesOwnJournalOverATwins() throws {
        let a = tempDir.appendingPathComponent("a.dng")
        let b = tempDir.appendingPathComponent("b.dng")
        let original = makeTIFF()
        try original.write(to: a)
        try original.write(to: b)

        // Both frames byte-identical and fixed the same way: each journal
        // claims both files' content, and b's is the newest.
        try fixer.fix(file: a, with: write, keepBak: false)
        try fixer.fix(file: b, with: write, keepBak: false)

        XCTAssertEqual(store.journalClaiming(a)?.journal.filePath, a.path)
        XCTAssertNoThrow(try fixer.fix(file: a, with: otherWrite, keepBak: false),
                         "a file with its own journal is not a renamed copy of another")

        try fixer.revert(file: a)
        XCTAssertEqual(try Data(contentsOf: a), original)
        XCTAssertEqual(store.fixedPaths(), [b.path])
    }

    func testContentMatchDistinguishesFramesWithTheSameLens() throws {
        // Two different frames, same lens: the patched regions are identical, so
        // only the sample of image data tells the journals apart.
        let b = tempDir.appendingPathComponent("b.dng")
        let a = tempDir.appendingPathComponent("a.dng")
        let originalB = makeTIFF(frame: 2)
        try originalB.write(to: b)
        try makeTIFF(frame: 1).write(to: a)

        try fixer.fix(file: b, with: write, keepBak: false)
        try fixer.fix(file: a, with: write, keepBak: false) // newest journal

        let renamed = tempDir.appendingPathComponent("b-imported.dng")
        try FileManager.default.moveItem(at: b, to: renamed)

        XCTAssertEqual(store.journalClaiming(renamed)?.journal.filePath, b.path,
                       "a renamed frame must match its own journal, not a newer one for another frame")
        try fixer.revert(file: renamed)
        XCTAssertEqual(try Data(contentsOf: renamed), originalB)
        XCTAssertEqual(store.fixedPaths(), [a.path])
    }

    // MARK: - Sealing a scan

    func testSealedURLsSealsARenamedFixedFile() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try fixer.fix(file: file, with: write, keepBak: false)

        let renamed = tempDir.appendingPathComponent("2026-07-26-0001.dng")
        try FileManager.default.moveItem(at: file, to: renamed)

        let result = store.sealedURLs(in: [renamed])
        XCTAssertEqual(result.sealed, [renamed], "a renamed frame keeps its seal")
        XCTAssertEqual(result.renamedFrom[renamed], "photo.dng")
    }

    func testSealedURLsDoesNotSealACopyWhileTheOriginalExists() throws {
        let a = tempDir.appendingPathComponent("a.dng")
        try makeTIFF().write(to: a)
        try fixer.fix(file: a, with: write, keepBak: false)
        let b = tempDir.appendingPathComponent("b.dng")
        try FileManager.default.copyItem(at: a, to: b)

        let result = store.sealedURLs(in: [a, b])
        XCTAssertEqual(result.sealed, [a], "the copy has no undo record of its own")
        XCTAssertTrue(result.renamedFrom.isEmpty)
    }

    func testSealedURLsSealsNeitherOfTwoFilesClaimingOneJournal() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        try makeTIFF().write(to: file)
        try fixer.fix(file: file, with: write, keepBak: false)

        // The fixed frame renamed, and a copy of it alongside: one journal,
        // two claimants, no honest seal.
        let one = tempDir.appendingPathComponent("one.dng")
        let two = tempDir.appendingPathComponent("two.dng")
        try FileManager.default.moveItem(at: file, to: one)
        try FileManager.default.copyItem(at: one, to: two)

        XCTAssertTrue(store.sealedURLs(in: [one, two]).sealed.isEmpty)
    }

    func testRevertReportsAJournalItCannotDelete() throws {
        let file = tempDir.appendingPathComponent("photo.dng")
        let original = makeTIFF()
        try original.write(to: file)
        try fixer.fix(file: file, with: write, keepBak: false)

        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                             ofItemAtPath: store.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: store.directory.path)
        }

        XCTAssertThrowsError(try fixer.revert(file: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be deleted"),
                          "unexpected error: \(error.localizedDescription)")
        }
        XCTAssertEqual(try Data(contentsOf: file), original, "the bytes still went back")
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
