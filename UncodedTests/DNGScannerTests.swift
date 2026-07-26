import XCTest
@testable import Uncoded

final class DNGScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UncodedScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func u16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private func u32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    /// Smallest structurally valid little-endian TIFF: IFD0 with one Make entry.
    private func minimalTIFF() -> Data {
        let make = Data("Leica Camera AG".utf8) + Data([0])
        let makeOffset = 8 + 2 + 12 + 4
        var data = Data("II".utf8) + u16(42) + u32(8)
        data += u16(1)
        data += u16(0x010F) + u16(2) + u32(UInt32(make.count)) + u32(UInt32(makeOffset))
        data += u32(0)
        data += make
        return data
    }

    func testEmptyFolderIsReadableWithNoFiles() {
        let outcome = DNGScanner.scan(folder: root)
        XCTAssertTrue(outcome.files.isEmpty)
        XCTAssertEqual(outcome.unreadable, 0)
        XCTAssertTrue(outcome.folderReadable)
    }

    func testUnreadableDNGsAreCountedNotDropped() throws {
        try minimalTIFF().write(to: root.appendingPathComponent("good.dng"))
        try Data("not a tiff".utf8).write(to: root.appendingPathComponent("bad.dng"))
        try Data("ignored".utf8).write(to: root.appendingPathComponent("photo.jpg"))

        let outcome = DNGScanner.scan(folder: root)
        XCTAssertEqual(outcome.files.count, 1)
        XCTAssertEqual(outcome.files.first?.filename, "good.dng")
        XCTAssertEqual(outcome.unreadable, 1)
        XCTAssertTrue(outcome.folderReadable)
    }

    func testMissingFolderReportsUnreadableRatherThanEmpty() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        let outcome = DNGScanner.scan(folder: missing)
        XCTAssertFalse(outcome.folderReadable)
        XCTAssertTrue(outcome.files.isEmpty)
    }

    /// Stand-in for a TCC-blocked folder: listable-by-nobody.
    func testUnlistableFolderReportsUnreadable() throws {
        let fm = FileManager.default
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try fm.createDirectory(at: denied, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }

        let outcome = DNGScanner.scan(folder: denied)
        XCTAssertFalse(outcome.folderReadable)
        XCTAssertTrue(outcome.files.isEmpty)
    }

    func testSingleDNGFileScansAsOneFrame() throws {
        let file = root.appendingPathComponent("single.dng")
        try minimalTIFF().write(to: file)
        let outcome = DNGScanner.scan(folder: file)
        XCTAssertEqual(outcome.files.count, 1)
        XCTAssertTrue(outcome.folderReadable)
    }
}
