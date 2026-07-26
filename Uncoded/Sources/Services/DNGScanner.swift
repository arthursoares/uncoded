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
    /// What a scan found. An empty `files` list is ambiguous on its own —
    /// no DNGs, DNGs we weren't allowed to read, a subtree that was skipped,
    /// or a folder that never opened — so the counts travel with it.
    struct Outcome: Sendable {
        var files: [ScannedDNG] = []
        var unreadable = 0
        /// Subfolders the walk couldn't open. Their DNGs are simply absent from
        /// `files`, so a complete-looking scan would otherwise be a lie.
        var skippedSubfolders = 0
        var folderReadable = true
    }

    static func scan(folder: URL) -> Outcome {
        let fm = FileManager.default
        var urls: [URL] = []
        var skipped = 0

        if folder.hasDirectoryPath {
            // access(R_OK) can still succeed where TCC blocks opendir, so probe
            // by actually listing the directory.
            guard (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) != nil,
                  let found = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                            options: [],
                                            errorHandler: { _, _ in
                                                // Keep walking the rest of the
                                                // tree; the count is surfaced.
                                                skipped += 1
                                                return true
                                            })
            else { return Outcome(folderReadable: false) }
            for case let url as URL in found where url.pathExtension.lowercased() == "dng" {
                urls.append(url)
            }
        } else if folder.pathExtension.lowercased() == "dng" {
            urls = [folder]
        }

        var outcome = Outcome()
        outcome.skippedSubfolders = skipped
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let meta = try? TIFFReader.read(url: url) else {
                outcome.unreadable += 1
                continue
            }
            outcome.files.append(ScannedDNG(
                url: url, meta: meta,
                codeCandidates: SixBitTable.matchCandidates(lensModel: meta.lensModel)))
        }
        return outcome
    }
}
