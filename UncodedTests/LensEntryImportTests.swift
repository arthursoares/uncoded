import SwiftData
import XCTest
@testable import Uncoded

final class LensEntryImportTests: XCTestCase {
    private func selection(_ name: String = "Voigtlander VM 35mm f/2 Ultron", codes: [String] = []) -> LensEntryImport.Selection {
        LensEntryImport.Selection(entry: ReferenceLensImporter.Entry(
            name: name, make: "Voigtlander", focalLength: "35mm", aperture: "f/2",
            profileName: "Adobe (Ultron)", profileFilename: "Ultron.lcp", profileDigest: "ABC123",
            sourceFilenames: ["reference.dng"]), codes: codes)
    }

    @MainActor
    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: UserLens.self, CodeMapping.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @MainActor
    func testImportPreservesLensFieldsAndEveryMapping() throws {
        let context = try context()
        XCTAssertEqual(try LensEntryImport.save([selection(codes: ["000110", "011110"])], in: context), 1)
        let lens = try XCTUnwrap(context.fetch(FetchDescriptor<UserLens>()).first)
        XCTAssertEqual(lens.name, "Voigtlander VM 35mm f/2 Ultron")
        XCTAssertEqual(lens.make, "Voigtlander")
        XCTAssertEqual(lens.focalLength, "35mm")
        XCTAssertEqual(lens.aperture, "f/2")
        XCTAssertEqual(lens.profileName, "Adobe (Ultron)")
        XCTAssertEqual(lens.profileFilename, "Ultron.lcp")
        XCTAssertEqual(lens.profileDigest, "ABC123")
        XCTAssertEqual(Set(lens.mappings.map(\.code)), ["000110", "011110"])
    }

    @MainActor
    func testUnmappedImportAndDeselectedEntries() throws {
        let context = try context()
        var skipped = selection("Skipped lens")
        skipped.included = false
        XCTAssertEqual(try LensEntryImport.save([selection(), skipped], in: context), 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserLens>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CodeMapping>()).isEmpty)
    }

    @MainActor
    func testExistingLensIsNeverOverwritten() throws {
        let context = try context()
        let existing = UserLens(name: "Voigtlander VM 35mm f/2 Ultron", make: "Original", profileDigest: "KEEP")
        context.insert(existing)
        try context.save()

        XCTAssertThrowsError(try LensEntryImport.save([selection(" voigtlander vm 35mm f/2 ULTRON ")], in: context))
        XCTAssertEqual(existing.make, "Original")
        XCTAssertEqual(existing.profileDigest, "KEEP")
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserLens>()).count, 1)
    }

    @MainActor
    func testExistingCodeIsNeverStolenAndBatchIsNotPartlyImported() throws {
        let context = try context()
        let owner = UserLens(name: "Existing lens", make: "Existing")
        context.insert(owner)
        Mappings.assign(code: "000110", to: owner, in: context)
        try context.save()

        XCTAssertThrowsError(try LensEntryImport.save([
            selection("Would otherwise import"), selection(codes: ["000110"])
        ], in: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<UserLens>()).map(\.name), ["Existing lens"])
        let mapping = try XCTUnwrap(context.fetch(FetchDescriptor<CodeMapping>()).first)
        XCTAssertIdentical(mapping.lens, owner)
    }

    func testConflictingVariantsAndDuplicateCodesRequireResolution() {
        XCTAssertNotNil(LensEntryImport.validation([selection("Lens"), selection(" lens ")], lenses: [], mappings: []))
        XCTAssertNotNil(LensEntryImport.validation([
            selection("One", codes: ["000110"]), selection("Two", codes: ["000110"])
        ], lenses: [], mappings: []))
    }

    func testMalformedFieldsAreRejectedButMissingSpecsAreAllowed() {
        for invalid in ["nan", "inf", "-35", "35-50mm"] {
            var draft = selection()
            draft.entry.focalLength = invalid
            XCTAssertNotNil(LensEntryImport.validation([draft], lenses: [], mappings: []), invalid)
        }
        XCTAssertNotNil(LensEntryImport.validation([selection("   ")], lenses: [], mappings: []))
        XCTAssertNotNil(LensEntryImport.validation([selection(codes: ["not-a-code"])], lenses: [], mappings: []))
        var draft = selection()
        draft.entry.focalLength = ""
        draft.entry.aperture = ""
        XCTAssertNil(LensEntryImport.validation([draft], lenses: [], mappings: []))
    }
}
