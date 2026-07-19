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

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let fieldOffset: Int // absolute offset of the 4-byte value/offset field
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
    static func read(url: URL) throws -> LensMetadata {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
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

    private func parseIFD(at offset: Int) throws -> [UInt16: Entry] {
        guard let countRaw = Self.u16(data, at: offset, littleEndian: littleEndian) else {
            throw ReadError.truncated
        }
        let count = Int(countRaw)
        guard offset + 2 + count * 12 <= data.count else { throw ReadError.truncated }

        var entries: [UInt16: Entry] = [:]
        for i in 0..<count {
            let base = offset + 2 + i * 12
            guard let tag = Self.u16(data, at: base, littleEndian: littleEndian),
                  let type = Self.u16(data, at: base + 2, littleEndian: littleEndian),
                  let entryCount = Self.u32(data, at: base + 4, littleEndian: littleEndian)
            else { throw ReadError.truncated }
            entries[tag] = Entry(tag: tag, type: type, count: Int(entryCount), fieldOffset: base + 8)
        }
        return entries
    }

    private static let typeSizes: [UInt16: Int] = [
        1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8,
    ]

    /// The raw bytes of an entry's value, whether inline or at an offset.
    private func valueData(_ entry: Entry) -> Data? {
        let size = (Self.typeSizes[entry.type] ?? 1) * entry.count
        var start = entry.fieldOffset
        if size > 4 {
            guard let offset = Self.u32(data, at: entry.fieldOffset, littleEndian: littleEndian) else { return nil }
            start = Int(offset)
        }
        guard start >= 0, start + size <= data.count else { return nil }
        return data.subdata(in: start..<(start + size))
    }

    private func ascii(_ entry: Entry?) -> String? {
        guard let entry, let raw = valueData(entry) else { return nil }
        let trimmed = raw.prefix { $0 != 0 }
        guard let s = String(data: trimmed, encoding: .utf8) else { return nil }
        let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// SHORT or LONG scalar value (used for IFD pointers).
    private func uintValue(_ entry: Entry) -> UInt32? {
        switch entry.type {
        case 3: return Self.u16(data, at: entry.fieldOffset, littleEndian: littleEndian).map(UInt32.init)
        case 4: return Self.u32(data, at: entry.fieldOffset, littleEndian: littleEndian)
        default: return nil
        }
    }

    /// Renders EXIF LensSpecification (4 rationals) as "50mm f/1.2" or "16-21mm f/4".
    private func lensSpecString(_ entry: Entry?) -> String? {
        guard let entry, entry.type == 5, entry.count == 4, let raw = valueData(entry) else { return nil }
        var values: [Double] = []
        for i in 0..<4 {
            guard let num = Self.u32(raw, at: i * 8, littleEndian: littleEndian),
                  let den = Self.u32(raw, at: i * 8 + 4, littleEndian: littleEndian), den != 0
            else { return nil }
            values.append(Double(num) / Double(den))
        }
        let focal = values[0] == values[1] ? fmt(values[0]) : "\(fmt(values[0]))-\(fmt(values[1]))"
        return "\(focal)mm f/\(fmt(values[2]))"
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    // MARK: - Primitive reads

    private static func u16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let a = UInt16(data[offset]), b = UInt16(data[offset + 1])
        return littleEndian ? (b << 8 | a) : (a << 8 | b)
    }

    private static func u32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32? {
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
                let value = String(xmp[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
