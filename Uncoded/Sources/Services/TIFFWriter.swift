import Foundation

/// The lens truth to write into a DNG.
struct LensWrite: Sendable {
    var lensMake: String
    var lensModel: String // also written to XMP aux:Lens
    var focalMM: Double? // e.g. 35.0
    var apertureF: Double? // e.g. 2.0
    var profileName: String
    var profileFilename: String
    var profileDigest: String
}

/// One in-place byte patch, with the original bytes for revert.
struct WritePatch: Codable {
    let offset: Int
    let original: Data
    let new: Data
}

/// Everything needed to undo a write: restore the patched bytes and truncate
/// away whatever was appended at end-of-file.
struct WriteJournal: Codable {
    let filePath: String
    let date: Date
    let originalLength: Int
    let patches: [WritePatch]
    let appendedBytes: Int
}

enum TIFFWriteError: Error, LocalizedError {
    case missingTag(String)
    case corruptStructure
    case fileChangedSinceFix

    var errorDescription: String? {
        switch self {
        case .missingTag(let tag): return "File has no \(tag) field to update"
        case .corruptStructure: return "File structure not understood; refusing to write"
        case .fileChangedSinceFix:
            return "This file changed since Uncoded fixed it — reverting would damage it. Restore the .bak copy instead."
        }
    }
}

/// In-place DNG metadata writer. Values that fit are patched where they are;
/// values that grew are appended at end-of-file and the IFD entry re-pointed;
/// missing entries trigger a rebuild of that IFD at end-of-file. The image
/// data is never touched and the file is never rewritten wholesale.
struct TIFFWriter {
    private let data: Data
    private let layout: TIFFReader.TIFFStructure
    private let originalLength: Int

    private var patches: [(offset: Int, new: Data)] = []
    private var appendix = Data()

    private enum Tag {
        static let xmp: UInt16 = 0x02BC
        static let exifIFD: UInt16 = 0x8769
        static let focalLength: UInt16 = 0x920A
        static let lensSpec: UInt16 = 0xA432
        static let lensMake: UInt16 = 0xA433
        static let lensModel: UInt16 = 0xA434
    }

    init(data: Data) throws {
        self.data = data
        self.originalLength = data.count
        self.layout = try TIFFReader(data: data).structure()
    }

    /// Applies the write to the file on disk and returns the journal.
    /// With `dryRun` the file is untouched and the journal describes what
    /// would change.
    static func apply(_ write: LensWrite, to url: URL, dryRun: Bool = false) throws -> WriteJournal {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var writer = try TIFFWriter(data: data)
        try writer.plan(write)
        let journal = writer.journal(for: url)
        if !dryRun {
            try writer.commit(to: url)
        }
        return journal
    }

    /// Restores a file to its pre-write state using the journal — but only
    /// after verifying the file is exactly as the write left it. If anything
    /// else touched the file since (Lightroom saving metadata, a re-fix, a
    /// different file at the same path), patching stale offsets would corrupt
    /// it, so we refuse instead.
    static func revert(_ journal: WriteJournal) throws {
        let url = URL(fileURLWithPath: journal.filePath)
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count == journal.originalLength + journal.appendedBytes else {
            throw TIFFWriteError.fileChangedSinceFix
        }
        for patch in journal.patches {
            let end = patch.offset + patch.new.count
            guard end <= data.count, data.subdata(in: patch.offset..<end) == patch.new else {
                throw TIFFWriteError.fileChangedSinceFix
            }
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for patch in journal.patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.original)
        }
        try handle.truncate(atOffset: UInt64(journal.originalLength))
        try handle.synchronize()
    }

    // MARK: - Planning

    private mutating func plan(_ write: LensWrite) throws {
        var exifAdditions: [NewEntry] = []

        try setString(Tag.lensMake, write.lensMake, in: layout.exif, additions: &exifAdditions)
        try setString(Tag.lensModel, write.lensModel, in: layout.exif, additions: &exifAdditions)

        if let focal = write.focalMM {
            try setRationals(Tag.focalLength, [focal], in: layout.exif, additions: &exifAdditions)
            if let aperture = write.apertureF {
                try setRationals(Tag.lensSpec, [focal, focal, aperture, aperture],
                                 in: layout.exif, additions: &exifAdditions)
            }
        }

        var newExifOffset: UInt32?
        if !exifAdditions.isEmpty {
            guard let exifOffset = layout.exifIFDOffset else { throw TIFFWriteError.missingTag("Exif IFD") }
            newExifOffset = UInt32(rebuildIFD(at: exifOffset, adding: exifAdditions))
        }

        try setXMP(write, newExifOffset: newExifOffset)

        // Re-point IFD0's Exif pointer if the Exif IFD moved (and IFD0 itself
        // wasn't rebuilt — setXMP handles the pointer when it rebuilds IFD0).
        if let newExifOffset, !rebuiltIFD0 {
            guard let pointer = layout.ifd0[Tag.exifIFD] else { throw TIFFWriteError.corruptStructure }
            patch(at: pointer.fieldOffset, u32Bytes(newExifOffset))
        }
    }

    private var rebuiltIFD0 = false

    /// Sets an ASCII tag: in-place when it fits, EOF append + entry re-point
    /// when it grew, IFD rebuild when the tag is missing.
    private mutating func setString(_ tag: UInt16, _ value: String,
                                    in ifd: [UInt16: TIFFReader.TIFFEntry],
                                    additions: inout [NewEntry]) throws {
        var bytes = Data(value.utf8)
        bytes.append(0)

        guard let entry = ifd[tag] else {
            additions.append(NewEntry(tag: tag, type: 2, count: bytes.count,
                                      valueField: valueField(for: bytes)))
            return
        }

        let oldSize = entry.count * (entry.type == 2 ? 1 : 1)
        if oldSize <= 4 {
            if bytes.count <= 4 {
                patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(bytes.count)))
                patch(at: entry.fieldOffset, bytes.padded(to: 4))
            } else {
                let offset = append(bytes)
                patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(bytes.count)))
                patch(at: entry.fieldOffset, u32Bytes(UInt32(offset)))
            }
        } else {
            guard let valueOffset = TIFFReader.u32(data, at: entry.fieldOffset, littleEndian: layout.littleEndian) else {
                throw TIFFWriteError.corruptStructure
            }
            if bytes.count <= oldSize {
                patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(bytes.count)))
                patch(at: Int(valueOffset), bytes)
            } else {
                let offset = append(bytes)
                patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(bytes.count)))
                patch(at: entry.fieldOffset, u32Bytes(UInt32(offset)))
            }
        }
    }

    /// Sets a RATIONAL tag (same count in place — rationals never change size).
    private mutating func setRationals(_ tag: UInt16, _ values: [Double],
                                       in ifd: [UInt16: TIFFReader.TIFFEntry],
                                       additions: inout [NewEntry]) throws {
        var bytes = Data()
        for v in values {
            bytes.append(u32Bytes(UInt32((v * 1000).rounded())))
            bytes.append(u32Bytes(1000))
        }

        guard let entry = ifd[tag] else {
            additions.append(NewEntry(tag: tag, type: 5, count: values.count,
                                      valueField: valueField(for: bytes)))
            return
        }
        guard entry.type == 5, entry.count == values.count,
              let valueOffset = TIFFReader.u32(data, at: entry.fieldOffset, littleEndian: layout.littleEndian)
        else { throw TIFFWriteError.corruptStructure }
        patch(at: Int(valueOffset), bytes)
    }

    /// Rewrites the XMP packet with the lens properties. Fits → in-place with
    /// whitespace padding; grew → EOF append + entry re-point; missing → new
    /// packet + IFD0 rebuild.
    private mutating func setXMP(_ write: LensWrite, newExifOffset: UInt32?) throws {
        let properties: [(String, String)] = [
            ("aux:Lens", write.lensModel),
            ("crs:LensProfileSetup", "Custom"),
            ("crs:LensProfileName", write.profileName),
            ("crs:LensProfileFilename", write.profileFilename),
            ("crs:LensProfileDigest", write.profileDigest),
            ("crs:LensProfileIsEmbedded", "False"),
        ]

        if let entry = layout.ifd0[Tag.xmp] {
            guard let valueOffset = TIFFReader.u32(data, at: entry.fieldOffset, littleEndian: layout.littleEndian),
                  entry.count > 4
            else { throw TIFFWriteError.corruptStructure }
            let oldBytes = data.subdata(in: Int(valueOffset)..<(Int(valueOffset) + entry.count))
            let oldXMP = String(data: oldBytes, encoding: .utf8) ?? Self.emptyPacket
            var newBytes = Data(Self.transformXMP(oldXMP, properties: properties).utf8)
            // The old packet's whitespace padding rides along in the transform;
            // strip it so the size check sees the real content, then re-pad.
            while let last = newBytes.last, last == 0x20 || last == 0x0A || last == 0x0D || last == 0x09 {
                newBytes.removeLast()
            }

            if newBytes.count <= entry.count {
                newBytes.append(Data(repeating: 0x20, count: entry.count - newBytes.count))
                patch(at: Int(valueOffset), newBytes)
            } else {
                let offset = append(newBytes)
                patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(newBytes.count)))
                patch(at: entry.fieldOffset, u32Bytes(UInt32(offset)))
            }
        } else {
            // No XMP at all: create a packet and rebuild IFD0 to reference it.
            let packet = Data(Self.transformXMP(Self.emptyPacket, properties: properties).utf8)
            var additions = [NewEntry(tag: Tag.xmp, type: 1, count: packet.count,
                                      valueField: valueField(for: packet))]
            if let newExifOffset {
                additions.append(NewEntry(tag: Tag.exifIFD, type: 4, count: 1,
                                          valueField: u32Bytes(newExifOffset)))
            }
            let newIFD0 = rebuildIFD(at: layout.ifd0Offset, adding: additions)
            patch(at: 4, u32Bytes(UInt32(newIFD0)))
            rebuiltIFD0 = true
        }
    }

    // MARK: - IFD rebuild

    private struct NewEntry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        let valueField: Data // exactly 4 bytes (inline value or offset)
    }

    /// Copies an IFD to the appendix with entries added/replaced (kept sorted
    /// by tag, as TIFF requires) and returns the new IFD's offset.
    private mutating func rebuildIFD(at offset: Int, adding: [NewEntry]) -> Int {
        let le = layout.littleEndian
        let count = Int(TIFFReader.u16(data, at: offset, littleEndian: le) ?? 0)

        var entries: [(tag: UInt16, bytes: Data)] = []
        for i in 0..<count {
            let base = offset + 2 + i * 12
            guard let tag = TIFFReader.u16(data, at: base, littleEndian: le) else { continue }
            var bytes = data.subdata(in: base..<(base + 12))
            // Absorb pending in-place patches that target this entry — the
            // entry is moving into the rebuilt IFD, so patching the old
            // location would strand them.
            patches.removeAll { patchItem in
                let end = patchItem.offset + patchItem.new.count
                guard patchItem.offset >= base, end <= base + 12 else { return false }
                let lower = patchItem.offset - base
                bytes.replaceSubrange(lower..<(lower + patchItem.new.count), with: patchItem.new)
                return true
            }
            entries.append((tag, bytes))
        }
        for new in adding {
            var bytes = u16Bytes(new.tag) + u16Bytes(new.type) + u32Bytes(UInt32(new.count))
            bytes.append(new.valueField)
            entries.removeAll { $0.tag == new.tag }
            entries.append((new.tag, bytes))
        }
        entries.sort { $0.tag < $1.tag }

        let nextPointer = data.subdata(in: (offset + 2 + count * 12)..<(offset + 2 + count * 12 + 4))

        var ifd = u16Bytes(UInt16(entries.count))
        for entry in entries { ifd.append(entry.bytes) }
        ifd.append(nextPointer)
        return append(ifd)
    }

    // MARK: - XMP transform

    static let emptyPacket = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""/>
    </rdf:RDF></x:xmpmeta>
    <?xpacket end="w"?>
    """

    private static let namespaces = [
        "aux": "http://ns.adobe.com/exif/1.0/aux/",
        "crs": "http://ns.adobe.com/camera-raw-settings/1.0/",
    ]

    /// Sets each property in the XMP text, replacing existing attribute or
    /// element forms, or inserting attributes on the first rdf:Description
    /// (declaring the namespace there when the document lacks it).
    static func transformXMP(_ xmp: String, properties: [(String, String)]) -> String {
        var result = xmp
        for (name, value) in properties {
            let escapedName = NSRegularExpression.escapedPattern(for: name)
            let escapedValue = xmlEscape(value)

            let attrPattern = escapedName + #"\s*=\s*"[^"]*""#
            if let regex = try? NSRegularExpression(pattern: attrPattern),
               regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: NSRegularExpression.escapedTemplate(for: "\(name)=\"\(escapedValue)\""))
                continue
            }

            let elemPattern = "(<" + escapedName + #"(?:\s[^>]*)?>)[^<]*(</"# + escapedName + ">)"
            if let regex = try? NSRegularExpression(pattern: elemPattern),
               regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) != nil {
                result = regex.stringByReplacingMatches(
                    in: result, range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: escapedValue) + "$2")
                continue
            }

            // Insert as attribute on the first rdf:Description. The namespace
            // must be declared in scope of THAT element (ancestors or the
            // element itself) — a declaration on a later sibling doesn't count.
            guard let tagStart = result.range(of: "<rdf:Description") else { continue }
            let tagEnd = result[tagStart.upperBound...].firstIndex(of: ">") ?? result.endIndex
            let scope = result[..<tagEnd]
            var insertion = " \(name)=\"\(escapedValue)\""
            let prefix = String(name.prefix(while: { $0 != ":" }))
            if let uri = namespaces[prefix], !scope.contains("xmlns:\(prefix)") {
                insertion = " xmlns:\(prefix)=\"\(uri)\"" + insertion
            }
            result.insert(contentsOf: insertion, at: tagStart.upperBound)
        }
        return result
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Patch/append plumbing

    private mutating func patch(at offset: Int, _ bytes: Data) {
        patches.append((offset, bytes))
    }

    /// Adds bytes to the end-of-file appendix (word-aligned, as TIFF values
    /// should sit at even offsets) and returns their absolute offset.
    private mutating func append(_ bytes: Data) -> Int {
        if (originalLength + appendix.count) % 2 == 1 { appendix.append(0) }
        let offset = originalLength + appendix.count
        appendix.append(bytes)
        return offset
    }

    /// A 4-byte IFD value field: inline when the value fits, otherwise an
    /// offset to the value appended at end-of-file.
    private mutating func valueField(for bytes: Data) -> Data {
        if bytes.count <= 4 { return bytes.padded(to: 4) }
        return u32Bytes(UInt32(append(bytes)))
    }

    private func u16Bytes(_ v: UInt16) -> Data {
        layout.littleEndian
            ? Data([UInt8(v & 0xFF), UInt8(v >> 8)])
            : Data([UInt8(v >> 8), UInt8(v & 0xFF)])
    }

    private func u32Bytes(_ v: UInt32) -> Data {
        let b = [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
        return layout.littleEndian ? Data(b) : Data(b.reversed())
    }

    // MARK: - Journal & commit

    private func journal(for url: URL) -> WriteJournal {
        let recorded = patches.map { patch -> WritePatch in
            let end = min(patch.offset + patch.new.count, originalLength)
            let original = patch.offset < originalLength
                ? data.subdata(in: patch.offset..<end)
                : Data()
            return WritePatch(offset: patch.offset, original: original, new: patch.new)
        }
        return WriteJournal(filePath: url.path, date: Date(),
                            originalLength: originalLength,
                            patches: recorded, appendedBytes: appendix.count)
    }

    private func commit(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        if !appendix.isEmpty {
            try handle.seekToEnd()
            try handle.write(contentsOf: appendix)
        }
        for patch in patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.new)
        }
        try handle.synchronize()
    }
}

private extension Data {
    func padded(to length: Int) -> Data {
        count >= length ? self : self + Data(repeating: 0, count: length - count)
    }
}
