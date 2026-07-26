import Foundation

/// One row of the Leica M 6-bit code table bundled with the app.
struct SixBitCode: Codable, Identifiable, Hashable, Sendable {
    let code: String // e.g. "011010"
    let lensName: String // e.g. "Summicron-M 28mm f/2 ASPH (I)"
    let productCodes: [String]
    let leicaIndex: String

    var id: String { code + lensName }

    /// The code as the six pit fields on the bayonet flange.
    var bits: [Bool] { code.map { $0 == "1" } }

    /// The table lists all 64 code indexes; the unused ones are "N/A"
    /// placeholders, not lenses, and nothing can be coded as one.
    var isLens: Bool { lensName.caseInsensitiveCompare("N/A") != .orderedSame }

    enum CodingKeys: String, CodingKey {
        case code
        case lensName = "lens_name"
        case productCodes = "product_codes"
        case leicaIndex = "leica_index"
    }
}

private final class BundleToken {}

/// The bundled 6-bit code table and lookups against it.
enum SixBitTable {
    static let all: [SixBitCode] = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "sixbit_codes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([SixBitCode].self, from: data)
        else { return [] }
        return rows
    }()

    /// Lens rows grouped by code string (several lens generations can share a
    /// code). Placeholders stay in `all` for completeness but not here.
    static let byCode: [String: [SixBitCode]] = Dictionary(grouping: all.filter(\.isLens), by: \.code)

    /// Unique code strings in table order, placeholders excluded.
    static let uniqueCodes: [String] = {
        var seen = Set<String>()
        return all.compactMap { $0.isLens && seen.insert($0.code).inserted ? $0.code : nil }
    }()

    /// Lens rows by full name, and by name without the generation marker the
    /// camera never writes.
    private static let index: (byName: [LensKey: [SixBitCode]], byBase: [String: [SixBitCode]]) = {
        var byName: [LensKey: [SixBitCode]] = [:]
        var byBase: [String: [SixBitCode]] = [:]
        for row in all where row.isLens {
            guard let key = LensNameParser.key(of: row.lensName) else { continue }
            byName[key, default: []].append(row)
            byBase[key.base, default: []].append(row)
        }
        return (byName, byBase)
    }()

    /// Matches a lens name in either Leica format (the camera writes
    /// "Noctilux-M 1:1.2/50 ASPH.", catalogs "Noctilux-M 50mm f/1.2 ASPH") to
    /// its table row, or nil when the name can't name one code.
    static func match(lensModel: String?) -> SixBitCode? {
        let candidates = matchCandidates(lensModel: lensModel)
        return candidates.count == 1 ? candidates.first : nil
    }

    /// The codes a lens name could mean, one row per code. Usually one; more
    /// when generations of the same lens wear different codes (Elmarit-M
    /// 28/2.8 III is 000011, IV is 011011) and the name — as camera strings do
    /// — carries no generation marker. Only the user knows which one is
    /// engraved, so callers must not guess.
    static func matchCandidates(lensModel: String?) -> [SixBitCode] {
        guard let lensModel, let key = LensNameParser.key(of: lensModel) else { return [] }
        // A name with a generation marker can name its exact row; without one
        // only the base can decide, and going through byName first would let
        // an unmarked row win beside marked generations.
        let rows = key.generation.isEmpty ? index.byBase[key.base] : index.byName[key] ?? index.byBase[key.base]
        guard let rows else { return [] }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.code).inserted }
    }

    /// Unique codes ordered by how plausible a borrow they are for the given
    /// lens: same focal length first, then nearest aperture. People borrow the
    /// Leica code closest to their lens's specs, so the right code should be
    /// the first suggestion.
    static func ranked(for identity: LensIdentity?) -> [String] {
        guard let identity else { return uniqueCodes }

        /// Distance of the closest lens behind a code, focal before aperture.
        func distance(_ code: String) -> (focal: Int, aperture: Int) {
            let ids = (byCode[code] ?? []).compactMap { LensNameParser.parse($0.lensName) }
            return ids.map { (abs($0.focalMM - identity.focalMM),
                              abs($0.apertureX100 - identity.apertureX100)) }
                .min { $0 < $1 } ?? (.max, .max)
        }

        let distances = uniqueCodes.map(distance)
        return uniqueCodes.indices
            .sorted { distances[$0] == distances[$1] ? $0 < $1 : distances[$0] < distances[$1] }
            .map { uniqueCodes[$0] }
    }
}
