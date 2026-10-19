import Foundation

/// A portable, data-only representation of the user's lens library.
///
/// Archives intentionally contain neither profile files nor any machine-local
/// paths. Decoding produces reviewable drafts; it never changes SwiftData.
enum LensSetupArchive {
    private static let format = "uncoded-lens-setup"
    private static let currentVersion = 1

    enum ArchiveError: Error, LocalizedError {
        case malformed(String)
        case wrongFormat(String)
        case unsupportedVersion(Int)
        case blankName(Int)
        case invalidCode(String, String)

        var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "This is not a valid Uncoded lens setup archive. \(detail)"
            case .wrongFormat(let found):
                return "This file has format \"\(found)\", not \"\(LensSetupArchive.format)\"."
            case .unsupportedVersion(let version):
                return "This lens setup archive uses unsupported version \(version). Update Uncoded and try again."
            case .blankName(let position):
                return "Lens \(position) has a blank name. Give every lens a name before importing."
            case .invalidCode(let code, let lensName):
                return "Lens \"\(lensName)\" has invalid 6-bit code \"\(code)\". Codes must contain exactly six 0 or 1 characters."
            }
        }
    }

    private struct Header: Decodable {
        let format: String
        let version: Int
    }

    private struct Archive: Codable {
        let format: String
        let version: Int
        let lenses: [Lens]
    }

    private struct Lens: Codable {
        let name: String
        let make: String
        let focalLength: String
        let aperture: String
        let profileName: String
        let profileFilename: String
        let profileDigest: String
        let codes: [String]

        @MainActor
        init(_ lens: UserLens) {
            name = lens.name
            make = lens.make
            focalLength = lens.focalLength
            aperture = lens.aperture
            profileName = lens.profileName
            profileFilename = lens.profileFilename
            profileDigest = lens.profileDigest
            codes = lens.mappings.map(\.code).sorted()
        }

        var fields: [String] {
            [name, make, focalLength, aperture, profileName, profileFilename, profileDigest]
        }
    }

    /// Encodes all supplied lenses and their code mappings in a stable order.
    @MainActor
    static func encode(lenses: [UserLens]) throws -> Data {
        let rows = lenses.map(Lens.init).sorted(by: comesBefore)
        try validate(rows)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Archive(format: format, version: currentVersion, lenses: rows))
    }

    /// Decodes editable import drafts without modifying the user's lens store.
    static func decode(_ data: Data, filename: String) throws -> [LensEntryImport.Selection] {
        let decoder = JSONDecoder()
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw ArchiveError.malformed(decodingDetail(error))
        }

        guard header.format == format else { throw ArchiveError.wrongFormat(header.format) }
        guard header.version == currentVersion else {
            throw ArchiveError.unsupportedVersion(header.version)
        }

        let archive: Archive
        do {
            archive = try decoder.decode(Archive.self, from: data)
        } catch {
            throw ArchiveError.malformed(decodingDetail(error))
        }
        try validate(archive.lenses)

        return archive.lenses.map { lens in
            let entry = ReferenceLensImporter.Entry(
                name: lens.name,
                make: lens.make,
                focalLength: lens.focalLength,
                aperture: lens.aperture,
                profileName: lens.profileName,
                profileFilename: lens.profileFilename,
                profileDigest: lens.profileDigest,
                sourceFilenames: [filename]
            )
            return LensEntryImport.Selection(entry: entry, included: true, codes: lens.codes)
        }
    }

    /// Reads a user-selected archive while balancing any security-scoped access.
    static func read(_ file: URL) throws -> [LensEntryImport.Selection] {
        let accessed = file.startAccessingSecurityScopedResource()
        defer {
            if accessed { file.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let filename = file.lastPathComponent.isEmpty ? "Lens setup archive" : file.lastPathComponent
        return try decode(data, filename: filename)
    }

    private static func validate(_ lenses: [Lens]) throws {
        for (index, lens) in lenses.enumerated() {
            guard !lens.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ArchiveError.blankName(index + 1)
            }
            for code in lens.codes where !isSixBitCode(code) {
                throw ArchiveError.invalidCode(code, lens.name)
            }
        }
    }

    private static func isSixBitCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0 == "0" || $0 == "1" }
    }

    private static func comesBefore(_ lhs: Lens, _ rhs: Lens) -> Bool {
        for (left, right) in zip(lhs.fields, rhs.fields) where left != right {
            return left < right
        }
        for (left, right) in zip(lhs.codes, rhs.codes) where left != right {
            return left < right
        }
        return lhs.codes.count < rhs.codes.count
    }

    private static func decodingDetail(_ error: Error) -> String {
        if let error = error as? DecodingError {
            switch error {
            case .dataCorrupted(let context), .keyNotFound(_, let context),
                    .typeMismatch(_, let context), .valueNotFound(_, let context):
                return context.debugDescription
            @unknown default:
                break
            }
        }
        return error.localizedDescription
    }
}
