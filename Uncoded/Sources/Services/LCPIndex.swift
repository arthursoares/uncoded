import Foundation

/// One Adobe lens-correction profile (.lcp) found on this machine.
struct LCPProfile: Identifiable, Hashable, Sendable {
    let url: URL
    let maker: String // top-level maker folder, e.g. "Voigtlander"
    let cameraMake: String? // stCamera:Make, "Leica Camera AG" for M-mount
    let cameraModel: String? // stCamera:Model, the body the profile was measured on
    let lensPrettyName: String? // stCamera:LensPrettyName
    let profileName: String? // stCamera:ProfileName

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
            profileName: delegate.attributes["stCamera:ProfileName"]
        )
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
