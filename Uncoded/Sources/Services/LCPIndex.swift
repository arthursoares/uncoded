import CryptoKit
import Foundation
import SwiftData

/// One Adobe lens-correction profile (.lcp) found on this machine.
struct LCPProfile: Identifiable, Hashable, Sendable {
    let url: URL
    let maker: String // top-level maker folder, e.g. "Voigtlander"
    let cameraMake: String? // stCamera:Make, "Leica Camera AG" for M-mount
    let cameraModel: String? // stCamera:Model, the body the profile was measured on
    let lensPrettyName: String? // stCamera:LensPrettyName
    let profileName: String? // stCamera:ProfileName
    /// What goes in XMP `crs:LensProfileDigest`: uppercase-hex MD5 of the .lcp
    /// file's bytes. Empty when the file could not be read.
    let digest: String

    var id: URL { url }
}

/// Indexes the .lcp lens profiles that Lightroom / Camera Raw install locally.
enum LCPIndex {
    static let defaultRoot = URL(fileURLWithPath: "/Library/Application Support/Adobe/CameraRaw/LensProfiles/1.0")

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: defaultRoot.path)
    }

    /// All M-mount profiles: files in each maker's "Leica" subfolder, plus
    /// everything under the Leica maker folder itself.
    static func indexMMount(root: URL = defaultRoot) -> [LCPProfile] {
        let fm = FileManager.default
        guard let makers = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        var files: [(url: URL, maker: String)] = []
        for makerDir in makers where makerDir.hasDirectoryPath {
            let maker = makerDir.lastPathComponent
            let scanRoot = maker == "Leica" ? makerDir : makerDir.appendingPathComponent("Leica")
            guard fm.fileExists(atPath: scanRoot.path),
                  let found = fm.enumerator(at: scanRoot, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in found where url.pathExtension.lowercased() == "lcp" {
                files.append((url, maker))
            }
        }

        // Adobe ships one .lcp per (lens, body) pair, and the Leica folder also
        // holds Leitz Phone profiles — dedupe per lens and keep camera lenses only.
        var seen = Set<String>()
        return files
            .compactMap { parse(url: $0.url, maker: $0.maker) }
            .filter { $0.cameraModel?.localizedCaseInsensitiveContains("phone") != true }
            .filter { $0.lensPrettyName.map { seen.insert($0).inserted } ?? true }
            .sorted { ($0.lensPrettyName ?? "") < ($1.lensPrettyName ?? "") }
    }

    /// Reads the stCamera attributes of the first camera-profile entry in an .lcp.
    static func parse(url: URL, maker: String) -> LCPProfile? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let delegate = FirstProfileDelegate()
        parser.delegate = delegate
        parser.parse() // aborted early by the delegate once attributes are found
        guard !delegate.attributes.isEmpty else { return nil }
        return LCPProfile(
            url: url,
            maker: maker,
            cameraMake: delegate.attributes["stCamera:Make"],
            cameraModel: delegate.attributes["stCamera:Model"],
            lensPrettyName: delegate.attributes["stCamera:LensPrettyName"],
            profileName: delegate.attributes["stCamera:ProfileName"],
            digest: digest(of: url) ?? ""
        )
    }

    /// The digest Lightroom stamps into `crs:LensProfileDigest` — the MD5 of the
    /// .lcp file's bytes, uppercase hex. MD5 is not a security choice here: it is
    /// the identifier Adobe already chose, so it has to match byte for byte or
    /// Lightroom will not recognise the profile reference.
    static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }
}

/// Keeps `UserLens.profileDigest` in step with the .lcp files actually installed.
///
/// v0.1.x left the digest empty on every lens, so every fix it made wrote
/// `crs:LensProfileDigest=""` — a profile reference Lightroom cannot resolve. The
/// .lcp filename was recorded though, and the digest is derived from the file, so
/// those rows can be repaired without asking the user anything.
///
/// The same trap catches a digest that was once right: Camera Raw ships a revised
/// .lcp under the same filename and every stored digest for it goes stale. The
/// digest exists only to name the file on this machine, so whenever the two
/// disagree the installed file wins.
enum LensProfileBackfill {
    /// Adopts the indexed digest wherever a lens's own differs. Returns how many
    /// lenses were repaired.
    @discardableResult
    static func run(in context: ModelContext, profiles: [LCPProfile]) throws -> Int {
        let lenses = try context.fetch(FetchDescriptor<UserLens>())
            .filter { !$0.profileFilename.isEmpty }
        guard !lenses.isEmpty else { return 0 }

        var digests: [String: String] = [:]
        for profile in profiles where !profile.digest.isEmpty {
            digests[profile.url.lastPathComponent.lowercased()] = profile.digest
        }

        var repaired = 0
        for lens in lenses {
            // A profile that isn't installed here says nothing about the digest
            // the lens holds — a Lightroom this app can't see may still have it.
            guard let digest = digests[lens.profileFilename.lowercased()],
                  digest != lens.profileDigest
            else { continue }
            lens.profileDigest = digest
            repaired += 1
        }
        if repaired > 0 { try context.save() }
        return repaired
    }

    /// Runs the backfill at launch. Indexing and hashing ~170 .lcp files is disk
    /// work, so it happens off the main actor on its own context; a failure is
    /// silent because the app is perfectly usable without it.
    static func runAtLaunch(container: ModelContainer) {
        Task.detached(priority: .utility) {
            let profiles = LCPIndex.indexMMount()
            guard !profiles.isEmpty else { return }
            _ = try? run(in: ModelContext(container), profiles: profiles)
        }
    }
}

/// Captures the attributes of the first rdf:Description that carries stCamera
/// data, then aborts parsing so large .lcp files cost almost nothing to index.
private final class FirstProfileDelegate: NSObject, XMLParserDelegate {
    var attributes: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        guard attributeDict.keys.contains(where: { $0.hasPrefix("stCamera:") }) else { return }
        attributes = attributeDict
        parser.abortParsing()
    }
}
