import Foundation

enum Search {
    /// Match-all-tokens search: every whitespace-separated word of the query
    /// must appear (case-insensitively) somewhere in the joined fields, in any
    /// order — so "voigtlander ultron" finds "Voigtlander VM 35mm f/2 Ultron".
    static func matches(_ query: String, in fields: [String?]) -> Bool {
        let tokens = query.lowercased().split(separator: " ")
        guard !tokens.isEmpty else { return true }
        let haystack = fields.compactMap { $0 }.joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}
