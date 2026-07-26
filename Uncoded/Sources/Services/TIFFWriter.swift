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

    /// Whether this lens names an Adobe correction profile at all. A lens the
    /// user typed in by hand names none — and then there is nothing truthful to
    /// put in `crs:LensProfile*`.
    var hasProfile: Bool {
        !(profileName.isEmpty && profileFilename.isEmpty && profileDigest.isEmpty)
    }

    /// XMP `aux:LensInfo`: min focal, max focal, min aperture, max aperture as
    /// space-separated rationals — the XMP twin of EXIF LensSpecification.
    ///
    /// The CLI's `exiftool -LensInfo=` populated *both* ExifIFD:LensInfo and
    /// XMP-aux:LensInfo. Writing only the EXIF one leaves the camera's original
    /// aux:LensInfo in place, which describes the *borrowed* Leica lens —
    /// usually at the wrong maximum aperture — and that is the copy Lightroom
    /// shows.
    var xmpLensInfo: String? {
        guard let focal = focalMM, let aperture = apertureF,
              let f = Self.rational(focal), let a = Self.rational(aperture)
        else { return nil }
        return "\(f) \(f) \(a) \(a)"
    }

    /// The shortest exact rational for a lens number: 35 → "35/1", 1.8 → "18/10".
    /// Unreduced denominators are valid XMP and are what Lightroom writes.
    private static func rational(_ v: Double) -> String? {
        guard v.isFinite, v > 0, v <= 1_000_000 else { return nil }
        var denominator = 1
        while denominator <= 1000 {
            let scaled = v * Double(denominator)
            if abs(scaled - scaled.rounded()) < 1e-6, scaled <= Double(UInt32.max) {
                return "\(Int(scaled.rounded()))/\(denominator)"
            }
            denominator *= 10
        }
        return nil
    }
}

/// One in-place byte patch, with the original bytes for revert.
struct WritePatch: Codable {
    let offset: Int
    let original: Data
    let new: Data
}

/// Everything needed to undo a write: restore the patched bytes and truncate
/// away whatever was appended at end-of-file.
///
/// The patches plus `sample` double as a content fingerprint: enough to
/// identify the file this journal belongs to — so a fixed file renamed after
/// the fix is still recognised — without hashing a 100 MB raw.
struct WriteJournal: Codable {
    let filePath: String
    let date: Date
    let originalLength: Int
    let patches: [WritePatch]
    let appendedBytes: Int
    // Added in v0.2. Optional, so journals written by v0.1.x still decode —
    // and so v0.1.x still decodes these (it ignores the extra keys).
    var originalFileName: String?
    var state: State?
    var bak: BakRecord?
    var sample: ContentSample?

    /// A journal is written before the bytes change, so a record on disk does
    /// not by itself mean the write happened.
    enum State: String, Codable {
        case pending
        case committed
    }

    /// Identity of the .bak Uncoded made, so a later fix can tell its own
    /// pristine backup from a stale or foreign one.
    struct BakRecord: Codable {
        let size: Int
        let modified: Date

        /// Modification dates survive a JSON round-trip as floating point;
        /// second granularity is all the identity check needs.
        func matches(_ other: BakRecord) -> Bool {
            size == other.size && abs(modified.timeIntervalSince(other.modified)) < 1
        }
    }

    /// A slice of the file outside every patched region — image data, in
    /// practice. The patched regions hold lens strings and a length, which two
    /// frames shot with the same lens share; this is what makes the fingerprint
    /// frame-unique. Absent in v0.1.x journals, which then match on the
    /// patches alone.
    struct ContentSample: Codable {
        let offset: Int
        let length: Int
        let hash: String

        /// FNV-1a: not a security hash, just a cheap wide one.
        static func hash(_ bytes: Data) -> String {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in bytes {
                h ^= UInt64(byte)
                h = h &* 0x0000_0100_0000_01B3
            }
            return String(h, radix: 16)
        }
    }

    /// v0.1.x journals were saved only after a successful write.
    var isCommitted: Bool { (state ?? .committed) == .committed }

    var fileName: String { originalFileName ?? URL(fileURLWithPath: filePath).lastPathComponent }

    /// Length the file has once the write has landed.
    var writtenLength: Int { originalLength + appendedBytes }

    /// True when `data` is exactly what this write leaves behind.
    func describesWrittenBytes(_ data: Data) -> Bool {
        guard appendedBytes >= 0, data.count == writtenLength else { return false }
        return patchesWritten(in: data)
    }

    /// True when `data` is still the pre-write file — the write never landed.
    func describesOriginalBytes(_ data: Data) -> Bool {
        data.count == originalLength && patchesUnwritten(in: data)
    }

    /// True when every patched region holds its post-write bytes. Says nothing
    /// about the file's length: the appendix can be there without the patches.
    func patchesWritten(in data: Data) -> Bool {
        guard originalLength >= 0, !patches.isEmpty, sampleMatches(data) else { return false }
        return patches.allSatisfy { holds($0.new, at: $0.offset, in: data) }
    }

    /// True when every patched region still holds its pre-write bytes.
    func patchesUnwritten(in data: Data) -> Bool {
        guard originalLength >= 0, !patches.isEmpty, sampleMatches(data) else { return false }
        return patches.allSatisfy { holds($0.original, at: $0.offset, in: data) }
    }

    /// The sample sits inside the original length and outside every patch, so
    /// it reads the same before and after the write.
    private func sampleMatches(_ data: Data) -> Bool {
        guard let sample else { return true }
        guard sample.offset >= 0, sample.length > 0, sample.offset <= data.count - sample.length
        else { return false }
        let slice = data.subdata(in: sample.offset..<(sample.offset + sample.length))
        return ContentSample.hash(slice) == sample.hash
    }

    private func holds(_ bytes: Data, at offset: Int, in data: Data) -> Bool {
        guard offset >= 0, !bytes.isEmpty, offset <= data.count - bytes.count else { return false }
        return data.subdata(in: offset..<(offset + bytes.count)) == bytes
    }

    /// The same write, recorded against a file that has moved since.
    func relocated(to url: URL) -> WriteJournal {
        guard url.path != filePath else { return self }
        return WriteJournal(filePath: url.path, date: date, originalLength: originalLength,
                            patches: patches, appendedBytes: appendedBytes,
                            originalFileName: fileName, state: state, bak: bak, sample: sample)
    }
}

enum TIFFWriteError: Error, LocalizedError {
    case missingTag(String)
    case corruptStructure
    case fileChangedSinceFix
    case nonTextTag(tag: UInt16, type: UInt16)
    case undecodableXMP
    case malformedXMP(String)
    case xmpMissingDescription
    case invalidValue(String)
    case fileTooLarge
    case fileChangedWhileWriting

    var errorDescription: String? {
        switch self {
        case .missingTag(let tag): return "File has no \(tag) field to update"
        case .corruptStructure: return "File structure not understood; refusing to write"
        case .fileChangedSinceFix:
            return "This file changed since Uncoded fixed it — reverting would damage it. Restore the .bak copy instead."
        case .nonTextTag(let tag, let type):
            return String(format: """
            Field 0x%04X holds TIFF type %d instead of the text type Uncoded \
            expects. Rewriting those bytes could destroy whatever the camera \
            put there, so this file is left untouched.
            """, tag, type)
        case .undecodableXMP:
            return "This file's XMP block is not UTF-8 text. Rewriting it would throw away metadata Uncoded cannot read (develop settings, ratings, GPS), so the file is left untouched."
        case .malformedXMP(let detail):
            return "This file's XMP block is not well-formed XML (\(detail)). Uncoded will not guess at where the lens properties belong in it, so the file is left untouched."
        case .xmpMissingDescription:
            return "This file's XMP block has no rdf:Description element to hold the lens properties; refusing rather than reporting a fix that only half happened."
        case .invalidValue(let detail): return detail
        case .fileTooLarge:
            return "File is too large for TIFF's 32-bit offsets; refusing to write"
        case .fileChangedWhileWriting:
            return "This file changed while Uncoded was preparing the fix; nothing was written. Try again."
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

    /// Value bytes are written (and flushed) before the pointers and counts
    /// that describe them, so an interrupted commit never leaves a field
    /// pointing at bytes that aren't on disk.
    private enum PatchKind {
        case value
        case pointer
    }

    private var patches: [(offset: Int, new: Data, kind: PatchKind)] = []
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

    /// A planned write: nothing on disk has been touched, but the journal that
    /// describes the change already exists. Splitting the two lets the caller
    /// persist the undo record *before* the bytes move.
    struct Prepared {
        let journal: WriteJournal
        fileprivate let writer: TIFFWriter
        fileprivate let url: URL

        func commit() throws { try writer.commit(to: url) }
    }

    /// Plans the write and returns it with its journal, unapplied.
    static func prepare(_ write: LensWrite, to url: URL) throws -> Prepared {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var writer = try TIFFWriter(data: data)
        try writer.plan(write)
        return Prepared(journal: writer.journal(for: url), writer: writer, url: url)
    }

    /// Applies the write to the file on disk and returns the journal.
    /// With `dryRun` the file is untouched and the journal describes what
    /// would change.
    static func apply(_ write: LensWrite, to url: URL, dryRun: Bool = false) throws -> WriteJournal {
        let prepared = try prepare(write, to: url)
        if !dryRun {
            try prepared.commit()
        }
        return prepared.journal
    }

    /// Restores a file to its pre-write state using the journal — but only
    /// after verifying the file is exactly as the write left it. If anything
    /// else touched the file since (Lightroom saving metadata, a re-fix, a
    /// different file at the same path), patching stale offsets would corrupt
    /// it, so we refuse instead.
    static func revert(_ journal: WriteJournal) throws {
        let url = URL(fileURLWithPath: journal.filePath)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // A journal is a file on disk like any other: treat its numbers as
        // untrusted too, or a hand-edited (or truncated) one traps here.
        guard journal.originalLength >= 0, journal.appendedBytes >= 0,
              journal.originalLength == data.count - journal.appendedBytes else {
            throw TIFFWriteError.fileChangedSinceFix
        }
        for patch in journal.patches {
            guard patch.offset >= 0, patch.original.count == patch.new.count,
                  patch.offset <= data.count - patch.new.count,
                  data.subdata(in: patch.offset..<(patch.offset + patch.new.count)) == patch.new
            else {
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
            try setRationals(Tag.focalLength, [focal], field: "Focal length",
                             in: layout.exif, additions: &exifAdditions)
        }
        // Its own statement rather than nested in the FocalLength write, though
        // LensSpecification does need the focal rationals: with no focal length
        // neither of the two EXIF fields is touched.
        if let focal = write.focalMM, let aperture = write.apertureF {
            try setRationals(Tag.lensSpec, [focal, focal, aperture, aperture],
                             field: "Lens specification", in: layout.exif, additions: &exifAdditions)
        }

        var newExifOffset: UInt32?
        if !exifAdditions.isEmpty {
            guard let exifOffset = layout.exifIFDOffset else { throw TIFFWriteError.missingTag("Exif IFD") }
            newExifOffset = try u32Offset(rebuildIFD(at: exifOffset, adding: exifAdditions))
        }

        try setXMP(write, newExifOffset: newExifOffset)

        // Re-point IFD0's Exif pointer if the Exif IFD moved (and IFD0 itself
        // wasn't rebuilt — setXMP handles the pointer when it rebuilds IFD0).
        if let newExifOffset, !rebuiltIFD0 {
            guard let pointer = layout.ifd0[Tag.exifIFD] else { throw TIFFWriteError.corruptStructure }
            try patch(at: pointer.fieldOffset, u32Bytes(newExifOffset), kind: .pointer)
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
                                      valueField: try valueField(for: bytes)))
            return
        }
        guard entry.type == 2 else { throw TIFFWriteError.nonTextTag(tag: tag, type: entry.type) }

        let oldSize = (TIFFReader.typeSizes[entry.type] ?? 1) * entry.count
        if oldSize <= 4 {
            if bytes.count <= 4 {
                try setCountAndField(entry, count: bytes.count, field: bytes.padded(to: 4))
            } else {
                let offset = try u32Offset(append(bytes))
                try setCountAndField(entry, count: bytes.count, field: u32Bytes(offset))
            }
        } else {
            guard let valueOffset = TIFFReader.u32(data, at: entry.fieldOffset, littleEndian: layout.littleEndian) else {
                throw TIFFWriteError.corruptStructure
            }
            if bytes.count <= oldSize {
                try patch(at: Int(valueOffset), bytes, kind: .value)
                try patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(bytes.count)), kind: .pointer)
            } else {
                let offset = try u32Offset(append(bytes))
                try setCountAndField(entry, count: bytes.count, field: u32Bytes(offset))
            }
        }
    }

    /// Updates an entry's count and value/offset fields as one 8-byte write.
    /// They are contiguous, and they only make sense together: a count that
    /// landed against the old offset describes bytes that aren't there.
    private mutating func setCountAndField(_ entry: TIFFReader.TIFFEntry,
                                           count: Int, field: Data) throws {
        try patch(at: entry.fieldOffset - 4, u32Bytes(UInt32(count)) + field, kind: .pointer)
    }

    /// Sets a RATIONAL tag (same count in place — rationals never change size).
    private mutating func setRationals(_ tag: UInt16, _ values: [Double], field: String,
                                       in ifd: [UInt16: TIFFReader.TIFFEntry],
                                       additions: inout [NewEntry]) throws {
        var bytes = Data()
        for v in values {
            // A nonsensical number must be reported, not truncated into a
            // trapping UInt32 conversion.
            guard v.isFinite, v > 0, v <= 1_000_000 else {
                throw TIFFWriteError.invalidValue("\(field) \(v) is out of range")
            }
            bytes.append(u32Bytes(UInt32((v * 1000).rounded())))
            bytes.append(u32Bytes(1000))
        }

        guard let entry = ifd[tag] else {
            additions.append(NewEntry(tag: tag, type: 5, count: values.count,
                                      valueField: try valueField(for: bytes)))
            return
        }
        guard entry.type == 5, entry.count == values.count,
              let valueOffset = TIFFReader.u32(data, at: entry.fieldOffset, littleEndian: layout.littleEndian)
        else { throw TIFFWriteError.corruptStructure }
        try patch(at: Int(valueOffset), bytes, kind: .value)
    }

    /// Rewrites the XMP packet with the lens properties. Fits → in-place with
    /// whitespace padding; grew → EOF append + entry re-point; missing → new
    /// packet + IFD0 rebuild.
    private mutating func setXMP(_ write: LensWrite, newExifOffset: UInt32?) throws {
        let properties = Self.xmpProperties(for: write)

        if let entry = layout.ifd0[Tag.xmp] {
            // entry.count is only a byte count for the one-byte-per-component
            // types; anything else and we don't know what we're looking at.
            guard [1, 2, 7].contains(entry.type) else {
                throw TIFFWriteError.nonTextTag(tag: Tag.xmp, type: entry.type)
            }
            guard let valueOffset = TIFFReader.u32(data, at: entry.fieldOffset, littleEndian: layout.littleEndian),
                  entry.count > 4
            else { throw TIFFWriteError.corruptStructure }
            let oldBytes = try slice(Int(valueOffset), entry.count)
            // A packet we can't decode is a packet we can't safely rewrite:
            // substituting an empty one would silently drop develop settings,
            // ratings and GPS. (A UTF-8 BOM decodes fine and round-trips.)
            guard let oldXMP = String(data: oldBytes, encoding: .utf8) else {
                throw TIFFWriteError.undecodableXMP
            }
            // transformXMP drops the old packet's padding, so this is the real
            // content size; the padding to fill the slot goes back on after.
            let newPacket = try Self.transformXMP(oldXMP, properties: properties)
            let newBytes = Data(newPacket.utf8)

            if newBytes.count <= entry.count {
                try patch(at: Int(valueOffset),
                          Self.padded(newPacket, toByteCount: entry.count), kind: .value)
            } else {
                let offset = try u32Offset(append(newBytes))
                try setCountAndField(entry, count: newBytes.count, field: u32Bytes(offset))
            }
        } else {
            // No XMP at all: create a packet and rebuild IFD0 to reference it.
            let packet = Data(try Self.transformXMP(Self.emptyPacket, properties: properties).utf8)
            var additions = [NewEntry(tag: Tag.xmp, type: 1, count: packet.count,
                                      valueField: try valueField(for: packet))]
            if let newExifOffset {
                additions.append(NewEntry(tag: Tag.exifIFD, type: 4, count: 1,
                                          valueField: u32Bytes(newExifOffset)))
            }
            let newIFD0 = try u32Offset(rebuildIFD(at: layout.ifd0Offset, adding: additions))
            try patch(at: 4, u32Bytes(newIFD0), kind: .pointer)
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
    private mutating func rebuildIFD(at offset: Int, adding: [NewEntry]) throws -> Int {
        let le = layout.littleEndian
        guard let countRaw = TIFFReader.u16(data, at: offset, littleEndian: le) else {
            throw TIFFWriteError.corruptStructure
        }
        let count = Int(countRaw)

        var entries: [(tag: UInt16, bytes: Data)] = []
        for i in 0..<count {
            let base = offset + 2 + i * 12
            guard let tag = TIFFReader.u16(data, at: base, littleEndian: le) else { continue }
            var bytes = try slice(base, 12)
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
        // An IFD's entry count is a UInt16: an IFD already near the limit plus
        // our additions can't be expressed, so refuse instead of trapping.
        guard entries.count <= Int(UInt16.max) else { throw TIFFWriteError.corruptStructure }
        entries.sort { $0.tag < $1.tag }

        let nextPointer = try slice(offset + 2 + count * 12, 4)

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

    /// The XMP properties one lens implies, in the order they are applied.
    ///
    /// A lens with no Adobe profile gets no `crs:LensProfile*` at all, and an
    /// empty value is never written: `LensProfileSetup="Custom"` beside an empty
    /// Digest/Filename/Name is a profile reference that names nothing, which is
    /// the leading explanation for fixes that changed the metadata and yet did
    /// nothing visible in Lightroom.
    static func xmpProperties(for write: LensWrite) -> [(String, String)] {
        var properties: [(String, String)] = [("aux:Lens", write.lensModel)]
        if let info = write.xmpLensInfo {
            properties.append(("aux:LensInfo", info))
        }
        guard write.hasProfile else { return properties }
        properties.append(("crs:LensProfileSetup", "Custom"))
        properties.append(("crs:LensProfileIsEmbedded", "False"))
        for (name, value) in [("crs:LensProfileName", write.profileName),
                              ("crs:LensProfileFilename", write.profileFilename),
                              ("crs:LensProfileDigest", write.profileDigest)]
        where !value.isEmpty {
            properties.append((name, value))
        }
        return properties
    }

    /// Sets each property in an XMP packet, replacing whichever form (attribute
    /// or element) the packet already uses and inserting an attribute otherwise.
    ///
    /// The XML in the packet is parsed, not pattern-matched: only a parser can
    /// tell `crs:LensProfileName` *of* an rdf:Description from the same text
    /// inside an `xmpMM:History` entry or a second Description, and only a
    /// parser knows that a `>` inside an attribute value doesn't end the tag.
    /// The `<?xpacket?>` processing instructions are peeled off and put back
    /// verbatim instead: the header carries a BOM, real M11 packets have a NUL
    /// byte after the trailer, and neither belongs to the document.
    static func transformXMP(_ xmp: String, properties: [(String, String)]) throws -> String {
        let packet = Packet(xmp)
        let document: XMLDocument
        do {
            // External entities are never resolved: this is XML out of a file we
            // did not write, and an XMP packet has no business fetching a DTD.
            document = try XMLDocument(xmlString: packet.body,
                                       options: [.nodePreserveWhitespace, .nodePreserveCDATA,
                                                 .nodeLoadExternalEntitiesNever])
        } catch {
            throw TIFFWriteError.malformedXMP(error.localizedDescription)
        }

        let descriptions = allDescriptions(in: document)
        // Prefer the Description that already carries the lens vocabulary — the
        // camera and Lightroom keep aux:/crs: together — else the first one.
        // None at all means there is nowhere to write, and reporting success
        // would mean an EXIF-only fix with the XMP untouched.
        guard let primary = descriptions.first(where: carriesLensVocabulary) ?? descriptions.first
        else { throw TIFFWriteError.xmpMissingDescription }

        for (name, value) in properties {
            // A property already present somewhere is updated *there*: adding a
            // second copy on `primary` would make the packet contradict itself.
            let target = descriptions.first { holds(name, $0) } ?? primary
            set(name, to: value, on: target)
        }

        let body = (document.children ?? [])
            .map { $0.xmlString(options: [.nodePreserveWhitespace]) }
            .joined()
        return packet.reassembled(body: body)
    }

    /// Every rdf:Description in the document, in document order.
    private static func allDescriptions(in node: XMLNode) -> [XMLElement] {
        var found: [XMLElement] = []
        if let element = node as? XMLElement, element.name == "rdf:Description" {
            found.append(element)
        }
        for child in node.children ?? [] {
            found.append(contentsOf: allDescriptions(in: child))
        }
        return found
    }

    private static func carriesLensVocabulary(_ element: XMLElement) -> Bool {
        let names = (element.attributes ?? []).compactMap(\.name)
            + (element.children ?? []).compactMap { ($0 as? XMLElement)?.name }
        return names.contains { $0.hasPrefix("aux:") || $0.hasPrefix("crs:") }
    }

    private static func holds(_ name: String, _ element: XMLElement) -> Bool {
        element.attribute(forName: name) != nil || !childElements(name, of: element).isEmpty
    }

    private static func childElements(_ name: String, of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
    }

    /// Writes one property onto one Description, keeping whichever form the
    /// packet already uses. A property held as both attribute and element is a
    /// duplicate either way, so the element form is dropped.
    private static func set(_ name: String, to value: String, on element: XMLElement) {
        if let attribute = element.attribute(forName: name) {
            attribute.stringValue = value
            for stale in childElements(name, of: element) { stale.detach() }
            return
        }
        if let existing = childElements(name, of: element).first {
            existing.stringValue = value
            return
        }
        declareNamespace(for: name, on: element)
        if let attribute = XMLNode.attribute(withName: name, stringValue: value) as? XMLNode {
            element.addAttribute(attribute)
        }
    }

    /// A prefixed attribute needs its namespace declared in scope of the element
    /// itself or an ancestor — a declaration on a sibling Description, which is
    /// how Lightroom writes them, does not count.
    private static func declareNamespace(for name: String, on element: XMLElement) {
        let prefix = String(name.prefix(while: { $0 != ":" }))
        guard let uri = namespaces[prefix] else { return }
        var scope: XMLElement? = element
        while let current = scope {
            if (current.namespaces ?? []).contains(where: { $0.name == prefix }) { return }
            scope = current.parent as? XMLElement
        }
        if let declaration = XMLNode.namespace(withName: prefix, stringValue: uri) as? XMLNode {
            element.addNamespace(declaration)
        }
    }

    /// Grows a packet to exactly `byteCount` bytes with whitespace padding,
    /// placed where the XMP spec puts it: after the XML and *before* the
    /// `<?xpacket end?>` trailer, so a reader that stops at the trailer has
    /// already seen the whole document. (v0.1.x appended it after the trailer.)
    static func padded(_ packet: String, toByteCount byteCount: Int) -> Data {
        let bytes = Data(packet.utf8)
        guard byteCount > bytes.count else { return bytes }
        // One byte per space in UTF-8, so the resulting length is exact.
        let spaces = String(repeating: " ", count: byteCount - bytes.count)
        guard let trailer = packet.range(of: Packet.trailerMarker, options: .backwards) else {
            return bytes + Data(spaces.utf8)
        }
        var padded = packet
        padded.insert(contentsOf: spaces, at: trailer.lowerBound)
        return Data(padded.utf8)
    }

    /// An XMP packet split into the parts an XML parser must not own: the
    /// `<?xpacket begin?>` header, the XML body, and the `<?xpacket end?>`
    /// trailer plus whatever the camera left after it (the M11 writes a NUL).
    struct Packet {
        static let trailerMarker = "<?xpacket end"

        let head: String
        let body: String
        let tail: String

        init(_ xmp: String) {
            // Trailing whitespace is padding that v0.1.x put on the wrong side
            // of the trailer; drop it and let the writer re-pad properly.
            var text = xmp
            while let last = text.last, last.isWhitespace { text.removeLast() }

            var rest = Substring(text)
            var head = ""
            if let begin = rest.range(of: "<?xpacket"),
               rest[..<begin.lowerBound].allSatisfy({ $0.isWhitespace || $0 == "\u{FEFF}" }),
               let close = rest.range(of: "?>", range: begin.upperBound..<rest.endIndex) {
                head = String(rest[..<close.upperBound])
                rest = rest[close.upperBound...]
            }
            var tail = ""
            if let end = rest.range(of: Self.trailerMarker, options: .backwards) {
                tail = String(rest[end.lowerBound...])
                rest = rest[..<end.lowerBound]
            }
            self.head = head
            self.tail = tail
            self.body = String(rest)
        }

        func reassembled(body: String) -> String {
            var out = head.isEmpty ? "" : head + "\n"
            out += body
            if !tail.isEmpty { out += "\n" + tail }
            return out
        }
    }

    // MARK: - Patch/append plumbing

    /// The single gate every in-place write passes through. Offsets come out
    /// of the file itself, so a corrupt DNG can aim one anywhere: a write past
    /// EOF would punch a sparse hole (and its length change would permanently
    /// defeat revert's guard), one inside the image data would corrupt pixels.
    /// Overlapping patches are refused too — the journal couldn't undo them.
    private mutating func patch(at offset: Int, _ bytes: Data, kind: PatchKind) throws {
        guard !bytes.isEmpty, offset >= 0, offset <= originalLength - bytes.count else {
            throw TIFFWriteError.corruptStructure
        }
        let end = offset + bytes.count
        guard !patches.contains(where: { offset < $0.offset + $0.new.count && $0.offset < end }) else {
            throw TIFFWriteError.corruptStructure
        }
        patches.append((offset, bytes, kind))
    }

    /// Bounds-checked read of the original bytes: the writer must never take a
    /// range from a file-supplied offset on trust.
    private func slice(_ start: Int, _ count: Int) throws -> Data {
        guard start >= 0, count >= 0, start <= originalLength - count else {
            throw TIFFWriteError.corruptStructure
        }
        return data.subdata(in: start..<(start + count))
    }

    /// TIFF offsets are 32-bit; a value that lands beyond 4 GB can't be
    /// pointed at, so refuse instead of trapping on the conversion.
    private func u32Offset(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= Int(UInt32.max) else { throw TIFFWriteError.fileTooLarge }
        return UInt32(offset)
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
    private mutating func valueField(for bytes: Data) throws -> Data {
        if bytes.count <= 4 { return bytes.padded(to: 4) }
        return u32Bytes(try u32Offset(append(bytes)))
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

    /// Patches in the order `commit` writes them, so the journal describes the
    /// file exactly as it will be left.
    private var orderedPatches: [(offset: Int, new: Data, kind: PatchKind)] {
        patches.filter { $0.kind == .value } + patches.filter { $0.kind == .pointer }
    }

    private func journal(for url: URL) -> WriteJournal {
        // patch(at:) guarantees every range lies inside the original file.
        let recorded = orderedPatches.map { patch in
            WritePatch(offset: patch.offset,
                       original: data.subdata(in: patch.offset..<(patch.offset + patch.new.count)),
                       new: patch.new)
        }
        return WriteJournal(filePath: url.path, date: Date(),
                            originalLength: originalLength,
                            patches: recorded, appendedBytes: appendix.count,
                            originalFileName: url.lastPathComponent,
                            state: .pending, sample: contentSample(besides: recorded))
    }

    /// Picks a window of untouched bytes near end-of-file — image data, on a
    /// real frame — to give the journal something no other frame shares.
    private func contentSample(besides recorded: [WritePatch]) -> WriteJournal.ContentSample? {
        let length = min(4096, originalLength / 4)
        guard length > 0 else { return nil }
        var offset = originalLength - length
        while offset >= 0 {
            let end = offset + length
            let clear = !recorded.contains { $0.offset < end && offset < $0.offset + $0.new.count }
            if clear {
                let slice = data.subdata(in: offset..<end)
                return WriteJournal.ContentSample(offset: offset, length: length,
                                                  hash: WriteJournal.ContentSample.hash(slice))
            }
            offset -= length
        }
        return nil
    }

    /// Write ordering is the whole safety story here: a crash or a full disk
    /// between two writes must never leave a pointer or count describing bytes
    /// that aren't on disk. So the appendix lands and is flushed first, then
    /// value bytes, then — last, after another flush — the pointers and counts
    /// that describe them. A half-finished commit is then still a readable file
    /// whose fields all point at real bytes.
    private func commit(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Every appendix offset was computed against the length we mapped, and
        // the appendix is written at the current end of file: if anything grew
        // the file since planning, all of those offsets are wrong.
        guard try handle.seekToEnd() == UInt64(originalLength) else {
            throw TIFFWriteError.fileChangedWhileWriting
        }
        if !appendix.isEmpty {
            try handle.write(contentsOf: appendix)
            try handle.synchronize()
        }
        for kind in [PatchKind.value, .pointer] {
            let group = patches.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            for patch in group {
                try handle.seek(toOffset: UInt64(patch.offset))
                try handle.write(contentsOf: patch.new)
            }
            try handle.synchronize()
        }
    }
}

private extension Data {
    func padded(to length: Int) -> Data {
        count >= length ? self : self + Data(repeating: 0, count: length - count)
    }
}
