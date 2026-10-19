import Foundation

/// Read-only TIFF/DNG metadata reader. Walks the IFD structures and XMP packet
/// directly — a few KB of a 50–100 MB DNG — and never touches the image data.
/// The file is memory-mapped, so only the pages actually read are paged in.
struct TIFFReader {
    enum ReadError: Error, LocalizedError {
        case notTIFF
        case truncated

        var errorDescription: String? {
            switch self {
            case .notTIFF: return "Not a TIFF/DNG file"
            case .truncated: return "File is truncated or corrupt"
            }
        }
    }

    /// Everything Uncoded needs to know about a file's lens claims.
    struct LensMetadata: Hashable, Sendable {
        var cameraMake: String?
        var cameraModel: String?
        var lensMake: String?
        var lensModel: String?
        var lensSpec: String? // rendered from EXIF LensSpecification, e.g. "50mm f/1.2"
        var auxLens: String? // XMP aux:Lens
        var auxLensInfo: String? // XMP aux:LensInfo, e.g. "35/1 35/1 2/1 2/1"
        var profileName: String? // XMP crs:LensProfileName
        var profileFilename: String? // XMP crs:LensProfileFilename
        var profileDigest: String? // XMP crs:LensProfileDigest
    }

    private enum Tag {
        static let make: UInt16 = 0x010F
        static let model: UInt16 = 0x0110
        static let xmp: UInt16 = 0x02BC
        static let exifIFD: UInt16 = 0x8769
        static let lensSpec: UInt16 = 0xA432
        static let lensMake: UInt16 = 0xA433
        static let lensModel: UInt16 = 0xA434
    }

    private let data: Data
    private let littleEndian: Bool
    private let ifd0Offset: Int

    init(data: Data) throws {
        self.data = data
        guard data.count >= 8 else { throw ReadError.truncated }
        switch (data[0], data[1]) {
        case (0x49, 0x49): littleEndian = true
        case (0x4D, 0x4D): littleEndian = false
        default: throw ReadError.notTIFF
        }
        // Byte-order-dependent reads need littleEndian set first; magic is 42.
        let magic = Self.u16(data, at: 2, littleEndian: littleEndian)
        guard magic == 42 else { throw ReadError.notTIFF }
        ifd0Offset = Int(Self.u32(data, at: 4, littleEndian: littleEndian) ?? 0)
        guard ifd0Offset >= 8, ifd0Offset < data.count else { throw ReadError.truncated }
    }

    /// Opens a DNG memory-mapped and extracts its lens metadata.
    /// `.mappedIfSafe` and not `.alwaysMapped`: a file on a card that gets
    /// pulled mid-scan would SIGBUS us on the next page fault.
    static func read(url: URL) throws -> LensMetadata {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try TIFFReader(data: data).lensMetadata()
    }

    func lensMetadata() throws -> LensMetadata {
        var meta = LensMetadata()

        let ifd0 = try parseIFD(at: ifd0Offset)
        meta.cameraMake = ascii(ifd0[Tag.make])
        meta.cameraModel = ascii(ifd0[Tag.model])

        if let xmpEntry = ifd0[Tag.xmp], let xmpData = valueData(xmpEntry),
           let xmp = String(data: xmpData, encoding: .utf8) {
            meta.auxLens = Self.xmpValue(xmp, property: "aux:Lens")
            // The copy Lightroom shows. The camera's own describes the borrowed
            // Leica lens, usually at the wrong maximum aperture.
            meta.auxLensInfo = Self.xmpValue(xmp, property: "aux:LensInfo")
            meta.profileName = Self.xmpValue(xmp, property: "crs:LensProfileName")
            meta.profileFilename = Self.xmpValue(xmp, property: "crs:LensProfileFilename")
            meta.profileDigest = Self.xmpValue(xmp, property: "crs:LensProfileDigest")
        }

        if let pointer = ifd0[Tag.exifIFD], let offset = uintValue(pointer) {
            let exif = try parseIFD(at: Int(offset))
            meta.lensMake = ascii(exif[Tag.lensMake])
            meta.lensModel = ascii(exif[Tag.lensModel])
            meta.lensSpec = lensSpecString(exif[Tag.lensSpec])
        }

        return meta
    }

    // MARK: - IFD parsing

    private func parseIFD(at offset: Int) throws -> [UInt16: TIFFEntry] {
        guard let countRaw = Self.u16(data, at: offset, littleEndian: littleEndian) else {
            throw ReadError.truncated
        }
        let count = Int(countRaw)
        // The 4-byte next-IFD pointer is part of the IFD: validate it here so
        // consumers (TIFFWriter's rebuild) can read the whole extent safely.
        guard offset >= 0, offset + 2 + count * 12 + 4 <= data.count else { throw ReadError.truncated }

        var entries: [UInt16: TIFFEntry] = [:]
        for i in 0..<count {
            let base = offset + 2 + i * 12
            guard let tag = Self.u16(data, at: base, littleEndian: littleEndian),
                  let type = Self.u16(data, at: base + 2, littleEndian: littleEndian),
                  let entryCount = Self.u32(data, at: base + 4, littleEndian: littleEndian)
            else { throw ReadError.truncated }
            entries[tag] = TIFFEntry(type: type, count: Int(entryCount), fieldOffset: base + 8)
        }
        return entries
    }

    /// TIFF type → bytes per component (also used by TIFFWriter).
    static let typeSizes: [UInt16: Int] = [
        1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8,
    ]

    /// The raw bytes of an entry's value, whether inline or at an offset.
    private func valueData(_ entry: TIFFEntry) -> Data? {
        let size = (Self.typeSizes[entry.type] ?? 1) * entry.count
        var start = entry.fieldOffset
        if size > 4 {
            guard let offset = Self.u32(data, at: entry.fieldOffset, littleEndian: littleEndian) else { return nil }
            start = Int(offset)
        }
        guard start >= 0, start + size <= data.count else { return nil }
        return data.subdata(in: start..<(start + size))
    }

    private func ascii(_ entry: TIFFEntry?) -> String? {
        guard let entry, let raw = valueData(entry) else { return nil }
        let trimmed = raw.prefix { $0 != 0 }
        guard let s = String(data: trimmed, encoding: .utf8) else { return nil }
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// SHORT or LONG scalar value (used for IFD pointers).
    private func uintValue(_ entry: TIFFEntry) -> UInt32? {
        switch entry.type {
        case 3: return Self.u16(data, at: entry.fieldOffset, littleEndian: littleEndian).map(UInt32.init)
        case 4: return Self.u32(data, at: entry.fieldOffset, littleEndian: littleEndian)
        default: return nil
        }
    }

    /// Renders EXIF LensSpecification (4 rationals) as "50mm f/1.2" or "16-21mm f/4".
    private func lensSpecString(_ entry: TIFFEntry?) -> String? {
        guard let entry, entry.type == 5, entry.count == 4, let raw = valueData(entry) else { return nil }
        var values: [Double] = []
        for i in 0..<4 {
            guard let num = Self.u32(raw, at: i * 8, littleEndian: littleEndian),
                  let den = Self.u32(raw, at: i * 8 + 4, littleEndian: littleEndian), den != 0
            else { return nil }
            values.append(Double(num) / Double(den))
        }
        return Self.lensSpecText(minFocal: values[0], maxFocal: values[1], aperture: values[2])
    }

    /// The rendering `LensMetadata.lensSpec` uses, exposed so a `LensWrite` can
    /// say what this field would read as once the write lands — without a
    /// second copy of the format to drift out of step with this one.
    static func lensSpecText(minFocal: Double, maxFocal: Double, aperture: Double) -> String {
        let focal = minFocal == maxFocal ? fmt(minFocal) : "\(fmt(minFocal))-\(fmt(maxFocal))"
        return "\(focal)mm f/\(fmt(aperture))"
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    // MARK: - Structure (for TIFFWriter)

    /// One IFD entry's location in the file. `fieldOffset` is the absolute
    /// offset of the entry's 4-byte value/offset field; the count field sits
    /// at `fieldOffset - 4`.
    struct TIFFEntry {
        let type: UInt16
        let count: Int
        let fieldOffset: Int
    }

    /// The parsed layout of the file's lens-relevant IFDs.
    struct TIFFStructure {
        let littleEndian: Bool
        let ifd0Offset: Int
        let exifIFDOffset: Int?
        let ifd0: [UInt16: TIFFEntry]
        let exif: [UInt16: TIFFEntry]
    }

    func structure() throws -> TIFFStructure {
        let ifd0 = try parseIFD(at: ifd0Offset)
        var exif: [UInt16: TIFFEntry] = [:]
        var exifOffset: Int?
        if let pointer = ifd0[Tag.exifIFD], let offset = uintValue(pointer) {
            exifOffset = Int(offset)
            exif = try parseIFD(at: Int(offset))
        }
        return TIFFStructure(littleEndian: littleEndian, ifd0Offset: ifd0Offset,
                             exifIFDOffset: exifOffset, ifd0: ifd0, exif: exif)
    }

    // MARK: - Primitive reads

    static func u16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
        return littleEndian ? (b << 8 | a) : (a << 8 | b)
    }

    static func u32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[offset]), b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2]), b3 = UInt32(data[offset + 3])
        return littleEndian
            ? (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
    }

    // MARK: - XMP

    /// Extracts an XMP property in either attribute (crs:X="…") or element
    /// (<crs:X>…</crs:X>) form.
    ///
    /// Decodes XML entities, including whitespace references emitted by the
    /// writer, so readback compares equal to the original lens values.
    static func xmpValue(_ xmp: String, property: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        for pattern in [
            escaped + #"\s*=\s*"([^"]*)""#,
            "<" + escaped + #"(?:\s[^>]*)?>([^<]*)</"# + escaped + ">",
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(xmp.startIndex..., in: xmp)
            if let match = regex.firstMatch(in: xmp, range: range),
               let r = Range(match.range(at: 1), in: xmp) {
                let value = unescapedXML(String(xmp[r]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// XML text back to the characters it stands for: the five named entities
    /// and numeric character references in both bases.
    ///
    /// Decodes once from left to right: `&amp;lt;` must become `&lt;`, not `<`.
    /// Unknown references are preserved verbatim.
    static func unescapedXML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            out += text[index..<ampersand]
            let body = text.index(after: ampersand)
            // A reference is short; scanning to a semicolon a paragraph away
            // would swallow the text between them ("Cooke & Sons; est. 1893").
            let limit = text.index(body, offsetBy: 12, limitedBy: text.endIndex) ?? text.endIndex
            if let semicolon = text[body..<limit].firstIndex(of: ";"),
               let decoded = Self.decodedReference(text[body..<semicolon]) {
                out += decoded
                index = text.index(after: semicolon)
            } else {
                out.append("&")
                index = body
            }
        }
        out += text[index...]
        return out
    }

    /// The text between `&` and `;`, decoded — or nil if it names nothing.
    private static func decodedReference(_ body: Substring) -> String? {
        switch body {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: break
        }
        guard body.hasPrefix("#") else { return nil }
        let digits = body.dropFirst()
        let hex = digits.first == "x" || digits.first == "X"
        guard let value = UInt32(hex ? digits.dropFirst() : digits, radix: hex ? 16 : 10),
              let scalar = Unicode.Scalar(value)
        else { return nil }
        return String(Character(scalar))
    }
}
