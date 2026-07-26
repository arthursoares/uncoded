import Foundation

/// One scanned DNG and what it claims about its lens.
struct ScannedDNG: Identifiable, Hashable, Sendable {
    let url: URL
    let meta: TIFFReader.LensMetadata
    /// Borrowed Leica codes the LensModel could name — more than one when the
    /// camera string doesn't say which generation (see matchCandidates).
    let codeCandidates: [SixBitCode]

    /// The borrowed code, when the LensModel names exactly one.
    var matchedCode: SixBitCode? { codeCandidates.count == 1 ? codeCandidates.first : nil }

    var id: URL { url }
    var filename: String { url.lastPathComponent }

    /// The lens string the file currently claims, preferring EXIF over XMP.
    var claimedLens: String? { meta.lensModel ?? meta.auxLens }

    /// The lens the user's mappings send this file to, given a lookup from code
    /// to mapped lens. Candidates the user never mapped don't count, and a
    /// re-coded lens claiming several candidates is still one destination —
    /// only two different lenses are a real ambiguity.
    func mappedLens<Lens: Identifiable>(_ lensForCode: (String) -> Lens?) -> Lens? {
        let claimed = codeCandidates.compactMap { lensForCode($0.code) }
        guard let first = claimed.first, claimed.allSatisfy({ $0.id == first.id }) else { return nil }
        return first
    }
}

/// Recursively scans folders for DNGs and reads their lens claims.
enum DNGScanner {
    static func scan(folder: URL) -> [ScannedDNG] {
        let fm = FileManager.default
        var urls: [URL] = []

        if folder.hasDirectoryPath {
            guard let found = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
            for case let url as URL in found where url.pathExtension.lowercased() == "dng" {
                urls.append(url)
            }
        } else if folder.pathExtension.lowercased() == "dng" {
            urls = [folder]
        }

        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let meta = try? TIFFReader.read(url: url) else { return nil }
                return ScannedDNG(url: url, meta: meta,
                                  codeCandidates: SixBitTable.matchCandidates(lensModel: meta.lensModel))
            }
    }
}
