import SwiftData
import XCTest
@testable import Uncoded

final class LensSetupArchiveTests: XCTestCase {
    @MainActor
    func testRoundTripPreservesEveryFieldAndAllCodesDeterministically() throws {
        let context = try makeContext()
        let first = UserLens(
            name: "  MS Optical Sonnetar 50mm f/1.1  ",
            make: "MS Optical",
            focalLength: "50.0mm",
            aperture: "f/1.1",
            profileName: "",
            profileFilename: "",
            profileDigest: ""
        )
        let second = UserLens(
            name: "Voigtlander VM 35mm f/2 Ultron Aspherical",
            make: "Voigtlander & Sohn",
            focalLength: "35mm",
            aperture: "f/2",
            profileName: "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)",
            profileFilename: "Leica Camera AG (Voigtlander VM 35mm f2 Ultron Aspherical) - RAW.lcp",
            profileDigest: "03CBD374CCB89A292AD832BB830E440F"
        )
        context.insert(first)
        context.insert(second)
        for mapping in [
            CodeMapping(code: "111111", leicaLensName: "Legacy placeholder", lens: first),
            CodeMapping(code: "101010", leicaLensName: "Borrowed B", lens: second),
            CodeMapping(code: "000001", leicaLensName: "Borrowed A", lens: second),
        ] { context.insert(mapping) }
        try context.save()

        let data = try LensSetupArchive.encode(lenses: [second, first])
        let reorderedData = try LensSetupArchive.encode(lenses: [first, second])
        XCTAssertEqual(data, reorderedData)

        let selections = try LensSetupArchive.decode(data, filename: "My setup.uncoded.json")
        XCTAssertEqual(selections.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: selections.map { ($0.entry.name, $0) })

        let decodedFirst = try XCTUnwrap(byName[first.name])
        XCTAssertTrue(decodedFirst.included)
        XCTAssertEqual(decodedFirst.entry.name, first.name, "manual whitespace is preserved for review")
        XCTAssertEqual(decodedFirst.entry.make, first.make)
        XCTAssertEqual(decodedFirst.entry.focalLength, first.focalLength)
        XCTAssertEqual(decodedFirst.entry.aperture, first.aperture)
        XCTAssertEqual(decodedFirst.entry.profileName, first.profileName)
        XCTAssertEqual(decodedFirst.entry.profileFilename, first.profileFilename)
        XCTAssertEqual(decodedFirst.entry.profileDigest, first.profileDigest)
        XCTAssertEqual(decodedFirst.entry.sourceFilenames, ["My setup.uncoded.json"])
        XCTAssertEqual(decodedFirst.codes, ["111111"])

        let decodedSecond = try XCTUnwrap(byName[second.name])
        XCTAssertEqual(decodedSecond.entry.make, second.make)
        XCTAssertEqual(decodedSecond.entry.focalLength, second.focalLength)
        XCTAssertEqual(decodedSecond.entry.aperture, second.aperture)
        XCTAssertEqual(decodedSecond.entry.profileName, second.profileName)
        XCTAssertEqual(decodedSecond.entry.profileFilename, second.profileFilename)
        XCTAssertEqual(decodedSecond.entry.profileDigest, second.profileDigest)
        XCTAssertEqual(decodedSecond.codes, ["000001", "101010"])

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(#""format" : "uncoded-lens-setup""#))
        XCTAssertTrue(text.contains(#""version" : 1"#))
        XCTAssertFalse(text.contains("createdAt"))
        XCTAssertFalse(text.contains("leicaLensName"))
        XCTAssertFalse(text.contains("sourceFilenames"))
        XCTAssertFalse(text.contains(".dng"))
        XCTAssertFalse(text.contains("/Users/private/Pictures/reference.dng"))
    }

    @MainActor
    func testEmptyLibraryIsAValidClearlyIdentifiedArchive() throws {
        let data = try LensSetupArchive.encode(lenses: [])
        let selections = try LensSetupArchive.decode(data, filename: "empty.uncoded.json")
        XCTAssertTrue(selections.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["format"] as? String, "uncoded-lens-setup")
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual((object["lenses"] as? [Any])?.count, 0)
    }

    func testRejectsMalformedWrongFormatUnsupportedVersionAndInvalidCode() {
        assertDecodeFails(Data("not JSON".utf8), containing: "not a valid Uncoded")
        assertDecodeFails(Data(#"["not", "an", "archive"]"#.utf8), containing: "not a valid Uncoded")
        assertDecodeFails(json(format: "another-app", version: 1), containing: "not \"uncoded-lens-setup\"")
        assertDecodeFails(json(format: "uncoded-lens-setup", version: 99), containing: "unsupported version 99")
        assertDecodeFails(json(format: "uncoded-lens-setup", version: 1, code: "10102x"),
                          containing: "invalid 6-bit code")
        assertDecodeFails(json(format: "uncoded-lens-setup", version: 1, code: "10101"),
                          containing: "invalid 6-bit code")
        assertDecodeFails(json(format: "uncoded-lens-setup", version: 1, name: " \n "),
                          containing: "blank name")
    }

    func testReadDoesNotModifySourceFile() throws {
        let data = json(format: "uncoded-lens-setup", version: 1, code: "010101")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LensSetupArchiveTests-\(UUID().uuidString).uncoded.json")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let selections = try LensSetupArchive.read(url)

        XCTAssertEqual(selections.first?.entry.sourceFilenames, [url.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: UserLens.self, CodeMapping.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func assertDecodeFails(_ data: Data, containing text: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try LensSetupArchive.decode(data, filename: "bad.uncoded.json"),
                             file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(text),
                          "unexpected error: \(error.localizedDescription)", file: file, line: line)
        }
    }

    private func json(format: String, version: Int, code: String = "010101",
                      name: String = "Lens") -> Data {
        let object: [String: Any] = [
            "format": format,
            "version": version,
            "lenses": [[
                "name": name,
                "make": "Maker",
                "focalLength": "35mm",
                "aperture": "f/2",
                "profileName": "",
                "profileFilename": "",
                "profileDigest": "",
                "codes": [code],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
