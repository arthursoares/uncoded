import AppKit
import ImageIO

/// Extracts the JPEG preview embedded in a DNG — via ImageIO's thumbnail path,
/// so the raw image data is never decoded — and caches decoded thumbnails.
enum ThumbnailLoader {
    private static let cache = NSCache<NSURL, NSImage>()

    static func thumbnail(for url: URL, maxPixel: CGFloat = 512) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }

        return await Task.detached(priority: .utility) { () -> NSImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
            let thumbOptions = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
            let image = NSImage(cgImage: cg, size: .zero)
            cache.setObject(image, forKey: url as NSURL) // NSCache is thread-safe
            return image
        }.value
    }
}
