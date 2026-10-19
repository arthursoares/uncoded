import Foundation

/// Reads lens definitions from DNGs without changing the source files.
enum ReferenceLensImporter {
    struct Entry: Identifiable, Hashable, Sendable {
        let id: UUID
        var name: String
        var make: String
        var focalLength: String
        var aperture: String
        var profileName: String
        var profileFilename: String
        var profileDigest: String
        var sourceFilenames: [String]

        init(id: UUID = UUID(), name: String, make: String, focalLength: String,
             aperture: String, profileName: String, profileFilename: String,
             profileDigest: String, sourceFilenames: [String]) {
            self.id = id
            self.name = name
            self.make = make
            self.focalLength = focalLength
            self.aperture = aperture
            self.profileName = profileName
            self.profileFilename = profileFilename
            self.profileDigest = profileDigest
            self.sourceFilenames = sourceFilenames
        }
    }

    struct Failure: Identifiable, Sendable {
        let id: UUID
        let filename: String
        let message: String

        init(id: UUID = UUID(), filename: String, message: String) {
            self.id = id
            self.filename = filename
            self.message = message
        }
    }

    struct Result: Sendable {
        var entries: [Entry]
        var failures: [Failure]
    }

    enum ImportError: Error, LocalizedError {
        case missingLensName

        var errorDescription: String? {
            switch self {
            case .missingLensName:
                return "No usable lens name was found in EXIF LensModel or XMP aux:Lens"
            }
        }
    }

    /// Reads every file independently. A corrupt file never prevents usable
    /// lens definitions from the other selected files being returned.
    static func read(_ files: [URL]) -> Result {
        var entries: [Entry] = []
        var failures: [Failure] = []
        var entryIndex: [EntryKey: Int] = [:]

        for file in files {
            let filename = file.lastPathComponent.isEmpty ? file.path : file.lastPathComponent
            let accessed = file.startAccessingSecurityScopedResource()
            defer {
                if accessed { file.stopAccessingSecurityScopedResource() }
            }

            do {
                let metadata = try TIFFReader.read(url: file)
                let entry = try entry(from: metadata, filename: filename)
                let key = EntryKey(entry)
                if let index = entryIndex[key] {
                    if !entries[index].sourceFilenames.contains(filename) {
                        entries[index].sourceFilenames.append(filename)
                    }
                } else {
                    entryIndex[key] = entries.count
                    entries.append(entry)
                }
            } catch {
                failures.append(Failure(
                    filename: filename,
                    message: "Could not import \(filename): \(error.localizedDescription)"
                ))
            }
        }

        return Result(entries: entries, failures: failures)
    }

    static func entry(from metadata: TIFFReader.LensMetadata, filename: String) throws -> Entry {
        let exifName = cleaned(metadata.lensModel)
        let xmpName = cleaned(metadata.auxLens)
        guard let name = exifName ?? xmpName else { throw ImportError.missingLensName }

        let specs = metadataSpecs(metadata) ?? fallbackSpecs(name: name, metadata: metadata)
        return Entry(
            name: name,
            make: cleaned(metadata.lensMake) ?? "",
            focalLength: specs?.focalLength ?? "",
            aperture: specs?.aperture ?? "",
            profileName: metadata.profileName ?? "",
            profileFilename: metadata.profileFilename ?? "",
            profileDigest: metadata.profileDigest ?? "",
            sourceFilenames: [filename]
        )
    }

    // MARK: - Lens specifications

    private struct Specs {
        let focalLength: String
        let aperture: String
    }

    /// EXIF is the canonical copy. If it does not contain a usable prime-lens
    /// specification, use Lightroom's rational XMP twin. Zoom ranges are left
    /// blank rather than collapsed to one focal length.
    private static func metadataSpecs(_ metadata: TIFFReader.LensMetadata) -> Specs? {
        if let text = cleaned(metadata.lensSpec), let specs = renderedSpecs(text) {
            return specs
        }
        if let text = cleaned(metadata.auxLensInfo), let specs = rationalSpecs(text) {
            return specs
        }
        return nil
    }

    /// A name is a last resort only when neither metadata spec field exists.
    /// LensNameParser deliberately handles the two established name formats.
    private static func fallbackSpecs(name: String, metadata: TIFFReader.LensMetadata) -> Specs? {
        guard cleaned(metadata.lensSpec) == nil, cleaned(metadata.auxLensInfo) == nil,
              let identity = LensNameParser.parse(name)
        else { return nil }
        let aperture = Double(identity.apertureX100) / 100
        return Specs(focalLength: "\(identity.focalMM)mm",
                     aperture: "f/\(numberText(aperture))")
    }

    private static func renderedSpecs(_ text: String) -> Specs? {
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)mm\s+f/([0-9]+(?:\.[0-9]+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let focalRange = Range(match.range(at: 1), in: text),
              let apertureRange = Range(match.range(at: 2), in: text),
              let focal = Double(text[focalRange]), focal.isFinite, focal > 0,
              let aperture = Double(text[apertureRange]), aperture.isFinite, aperture > 0
        else { return nil }
        return Specs(focalLength: "\(text[focalRange])mm", aperture: "f/\(text[apertureRange])")
    }

    private struct Rational {
        let numerator: UInt64
        let denominator: UInt64

        var value: Double { Double(numerator) / Double(denominator) }

        func equals(_ other: Rational) -> Bool {
            let left = numerator.multipliedReportingOverflow(by: other.denominator)
            let right = other.numerator.multipliedReportingOverflow(by: denominator)
            return !left.overflow && !right.overflow && left.partialValue == right.partialValue
        }
    }

    private static func rationalSpecs(_ text: String) -> Specs? {
        let components = text.split(whereSeparator: \.isWhitespace)
        guard components.count == 4 else { return nil }
        let values = components.compactMap(parseRational)
        guard values.count == 4,
              values[0].equals(values[1]), values[2].equals(values[3]),
              values[0].value.isFinite, values[2].value.isFinite,
              values[0].value > 0, values[2].value > 0,
              values[0].value <= 1_000_000, values[2].value <= 1_000_000
        else { return nil }
        return Specs(focalLength: "\(numberText(values[0].value))mm",
                     aperture: "f/\(numberText(values[2].value))")
    }

    private static func parseRational(_ text: Substring) -> Rational? {
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let numerator = UInt64(pieces[0]), numerator > 0,
              let denominator = UInt64(pieces[1]), denominator > 0
        else { return nil }
        return Rational(numerator: numerator, denominator: denominator)
    }

    private static func numberText(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct EntryKey: Hashable {
        let name: String
        let make: String
        let focalLength: String
        let aperture: String
        let profileName: String
        let profileFilename: String
        let profileDigest: String

        init(_ entry: Entry) {
            name = entry.name
            make = entry.make
            focalLength = entry.focalLength
            aperture = entry.aperture
            profileName = entry.profileName
            profileFilename = entry.profileFilename
            profileDigest = entry.profileDigest
        }
    }
}
