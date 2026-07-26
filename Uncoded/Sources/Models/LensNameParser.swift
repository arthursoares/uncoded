import Foundation

/// A lens reduced to focal length and aperture, used to rank which Leica code
/// is the most plausible borrow for a third-party lens. Lossy on purpose — it
/// drops ASPH and generation markers, so it must never be used to look a lens
/// up in the code table (that's `LensKey`).
struct LensIdentity: Hashable, Sendable {
    let family: String // "noctilux"
    let focalMM: Int // 50
    let apertureX100: Int // 120 (f/1.2 × 100; ×10 would round f/0.95 onto f/1)
}

/// A full lens name reduced to a format-independent key: the camera writes
/// "Noctilux-M 1:1.2/50 ASPH." and catalogs "Noctilux-M 50mm f/1.2 ASPH",
/// both giving base "noctilux 50 120 asph". `generation` holds the markers
/// only catalogs carry ("iii", "fle ii"), so a catalog name can hit its exact
/// row while a camera name falls back to the base.
struct LensKey: Hashable, Sendable {
    let base: String
    let generation: String
}

enum LensNameParser {
    /// Parses either Leica naming format into a LensIdentity.
    /// Returns nil when no focal/aperture pair can be found.
    static func parse(_ name: String) -> LensIdentity? {
        guard let spec = spec(in: normalized(name)) else { return nil }
        let words = words(in: spec.rest)
        return LensIdentity(family: words.family.first ?? "",
                            focalMM: spec.focalMM, apertureX100: spec.apertureX100)
    }

    /// Parses either Leica naming format into the key used to look the lens up
    /// in the 6-bit code table. Returns nil when no focal/aperture pair can be
    /// found (the Macro-Adapter-M rows, the "N/A" placeholders).
    static func key(of name: String) -> LensKey? {
        guard let spec = spec(in: normalized(name)) else { return nil }
        let words = words(in: spec.rest)
        var base = words.family.joined(separator: " ")
        base += " \(spec.focalMM) \(spec.apertureX100)"
        if words.asph { base += " asph" }
        return LensKey(base: base, generation: words.generation.joined(separator: " "))
    }

    /// Some catalog entries use comma decimals ("f/1,25").
    private static func normalized(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: ",", with: ".")
    }

    /// The focal/aperture pair plus the name with the spec cut out.
    private static func spec(in lower: String) -> (focalMM: Int, apertureX100: Int, rest: String)? {
        // Format A (camera): "1:1.2/50" or "1:4/16-18-21"
        if let m = firstMatch(#"1:([0-9.]+)/([0-9.\-]+)"#, in: lower),
           let aperture = Double(m.groups[1]), aperture > 0 {
            // Multi-focal lenses list all focals; use the last one to agree
            // with format B, where the regex lands on the number next to "mm".
            let focalPart = m.groups[2].split(separator: "-").last.map(String.init) ?? m.groups[2]
            if let focal = Double(focalPart) {
                return (Int(focal.rounded()), Int((aperture * 100).rounded()),
                        lower.replacingCharacters(in: m.range, with: " "))
            }
        }

        // Format B (catalog): "50mm f/1.2", "16-18-21mm f/4"
        if let m = firstMatch(#"([0-9.]+)\s*mm\s*f/([0-9.]+)"#, in: lower),
           let focal = Double(m.groups[1]), let aperture = Double(m.groups[2]), aperture > 0 {
            return (Int(focal.rounded()), Int((aperture * 100).rounded()),
                    lower.replacingCharacters(in: m.range, with: " "))
        }

        return nil
    }

    /// Cosmetic and reissue variants don't change the code the lens wears.
    private static let noise: Set<String> = ["leica", "chrome", "titan", "black",
                                             "re", "steel", "rim", "mm", "f"]
    /// Markers naming a generation: "(IV)", "(FLE II)".
    private static let generations: Set<String> = ["i", "ii", "iii", "iv", "v", "fle"]

    /// Splits the name-without-spec into family words, generation markers and
    /// the ASPH flag. Leftover focal fragments ("16-18-") are dropped with
    /// everything else carrying digits.
    private static func words(in rest: String) -> (family: [String], generation: [String], asph: Bool) {
        var family: [String] = []
        var generation: [String] = []
        var asph = false
        for raw in rest.split(whereSeparator: { " ()/,".contains($0) }) {
            var token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if token.hasSuffix("-m") { token = String(token.dropLast(2)) } // mount marker
            if token.isEmpty || token.contains(where: \.isNumber) || noise.contains(token) { continue }
            if token == "asph" {
                asph = true
            } else if generations.contains(token) {
                generation.append(token)
            } else {
                family.append(token)
            }
        }
        return (family, generation, asph)
    }

    /// The capture groups and range of the first regex match, [0] being the full match.
    private static func firstMatch(_ pattern: String, in text: String)
        -> (groups: [String], range: Range<String.Index>)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let full = Range(match.range, in: text) else { return nil }
        let groups = (0..<match.numberOfRanges).map {
            guard let r = Range(match.range(at: $0), in: text) else { return "" }
            return String(text[r])
        }
        return (groups, full)
    }
}
