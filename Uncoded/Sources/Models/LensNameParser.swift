import Foundation

/// A lens reduced to the identity triple used to match names across formats:
/// the camera writes "Noctilux-M 1:1.2/50 ASPH." while catalogs write
/// "Noctilux-M 50mm f/1.2 ASPH" — both normalize to the same identity.
struct LensIdentity: Hashable, Sendable {
    let family: String // "noctilux"
    let focalMM: Int // 50
    let apertureX10: Int // 12 (f/1.2 × 10, avoids Double hashing issues)
}

enum LensNameParser {
    /// Parses either Leica naming format into a LensIdentity.
    /// Returns nil when no focal/aperture pair can be found.
    static func parse(_ name: String) -> LensIdentity? {
        // Some catalog entries use comma decimals ("f/1,25").
        let lower = name.lowercased().replacingOccurrences(of: ",", with: ".")

        guard let family = family(of: lower) else { return nil }

        // Format A (camera): "1:1.2/50" or "1:4/16-18-21"
        if let m = firstMatch(#"1:([0-9.]+)/([0-9.\-]+)"#, in: lower) {
            let aperture = Double(m[1]) ?? 0
            // Multi-focal lenses list all focals; use the last one to agree
            // with format B, where the regex lands on the number next to "mm".
            let focalPart = m[2].split(separator: "-").last.map(String.init) ?? m[2]
            if let focal = Double(focalPart), aperture > 0 {
                return LensIdentity(family: family, focalMM: Int(focal.rounded()),
                                    apertureX10: Int((aperture * 10).rounded()))
            }
        }

        // Format B (catalog): "50mm f/1.2", "16-18-21mm f/4"
        if let m = firstMatch(#"([0-9.]+)\s*mm\s*f/([0-9.]+)"#, in: lower) {
            if let focal = Double(m[1]), let aperture = Double(m[2]), aperture > 0 {
                return LensIdentity(family: family, focalMM: Int(focal.rounded()),
                                    apertureX10: Int((aperture * 10).rounded()))
            }
        }

        return nil
    }

    /// First word of the name with a trailing "-m" mount marker removed:
    /// "super-elmar-m" -> "super-elmar".
    private static func family(of lower: String) -> String? {
        guard var token = lower.split(separator: " ").first.map(String.init) else { return nil }
        if token.hasSuffix("-m") { token = String(token.dropLast(2)) }
        return token.isEmpty ? nil : token
    }

    /// Returns the capture groups of the first regex match, [0] being the full match.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map {
            guard let r = Range(match.range(at: $0), in: text) else { return "" }
            return String(text[r])
        }
    }
}
