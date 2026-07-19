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

    private static let byIdentity: [LensIdentity: SixBitCode] = {
        var map: [LensIdentity: SixBitCode] = [:]
        for row in all {
            if let id = LensNameParser.parse(row.lensName), map[id] == nil {
                map[id] = row
            }
        }
        return map
    }()

    /// Matches a camera-written lens string (e.g. "Noctilux-M 1:1.2/50 ASPH.")
    /// to its table entry, tolerating the different naming formats Leica uses.
    static func match(lensModel: String?) -> SixBitCode? {
        guard let lensModel, let id = LensNameParser.parse(lensModel) else { return nil }
        return byIdentity[id]
    }
}
