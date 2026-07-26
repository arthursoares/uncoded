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

    /// Codes grouped by code string (several lens generations can share a code).
    static let byCode: [String: [SixBitCode]] = Dictionary(grouping: all, by: \.code)

    /// Unique code strings in table order.
    static let uniqueCodes: [String] = {
        var seen = Set<String>()
        return all.compactMap { seen.insert($0.code).inserted ? $0.code : nil }
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
    /// its table row. The full name decides; a camera string, which omits the
    /// generation marker, falls back to the name without it.
    static func match(lensModel: String?) -> SixBitCode? {
        guard let lensModel, let key = LensNameParser.key(of: lensModel) else { return nil }
        if let row = singleCode(index.byName[key]) { return row }
        return singleCode(index.byBase[key.base])
    }

    /// The first candidate only when they all wear the same code: a name
    /// spanning two codes (Elmarit-M 28/2.8 III is 000011, IV is 011011) is
    /// unresolvable, and guessing would fix photos as the wrong lens.
    private static func singleCode(_ rows: [SixBitCode]?) -> SixBitCode? {
        guard let rows, Set(rows.map(\.code)).count == 1 else { return nil }
        return rows.first
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
