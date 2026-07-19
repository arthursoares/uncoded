import Foundation

/// One scanned DNG and what it claims about its lens.
struct ScannedDNG: Identifiable, Hashable, Sendable {
    let url: URL
    let meta: TIFFReader.LensMetadata
    let matchedCode: SixBitCode? // borrowed Leica code detected from LensModel

    var id: URL { url }
    var filename: String { url.lastPathComponent }

    /// The lens string the file currently claims, preferring EXIF over XMP.
    var claimedLens: String? { meta.lensModel ?? meta.auxLens }
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
                                  matchedCode: SixBitTable.match(lensModel: meta.lensModel))
            }
    }
}
