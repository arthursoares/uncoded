import Foundation
import SwiftData

/// A lens the user actually owns, with the Adobe correction profile to apply.
@Model
final class UserLens {
    var name: String
    var make: String
    var focalLength: String // e.g. "35.0mm"
    var aperture: String // e.g. "f/2"
    var profileName: String // e.g. "Adobe (Voigtlander VM 35mm f/2 Ultron Aspherical)"
    var profileFilename: String // the .lcp filename
    var profileDigest: String // Adobe profile digest, may be empty
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \CodeMapping.lens)
    var mappings: [CodeMapping] = []

    init(name: String, make: String, focalLength: String = "", aperture: String = "",
         profileName: String = "", profileFilename: String = "", profileDigest: String = "") {
        self.name = name
        self.make = make
        self.focalLength = focalLength
        self.aperture = aperture
        self.profileName = profileName
        self.profileFilename = profileFilename
        self.profileDigest = profileDigest
        self.createdAt = Date()
    }
}

extension UserLens {
    /// The metadata write this lens implies, parsing "35.0mm" and "f/2".
    var lensWrite: LensWrite {
        let focal = Double(focalLength.lowercased()
            .replacingOccurrences(of: "mm", with: "")
            .trimmingCharacters(in: .whitespaces))
        let aperture = Double(self.aperture.lowercased()
            .replacingOccurrences(of: "f/", with: "")
            .trimmingCharacters(in: .whitespaces))
        return LensWrite(lensMake: make, lensModel: name,
                         focalMM: focal, apertureF: aperture,
                         profileName: profileName,
                         profileFilename: profileFilename,
                         profileDigest: profileDigest)
    }
}

// MARK: - Recognising Uncoded's own output

extension UserLens {
    /// Matches a claimed name after trimming, ignoring case. Scan planning uses
    /// this only when no Leica code matches, so previously fixed files can be
    /// repaired even without an undo journal.
    static func claiming(name: String?, in lenses: [UserLens]) -> UserLens? {
        guard let claimed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !claimed.isEmpty
        else { return nil }
        return lenses.first {
            let own = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !own.isEmpty && own.compare(claimed, options: .caseInsensitive) == .orderedSame
        }
    }

    /// The lens a file's metadata claims: EXIF LensModel first, XMP `aux:Lens`
    /// as the fallback — a half-landed fix can leave the two disagreeing.
    static func claiming(_ metadata: TIFFReader.LensMetadata, in lenses: [UserLens]) -> UserLens? {
        claiming(name: metadata.lensModel, in: lenses)
            ?? claiming(name: metadata.auxLens, in: lenses)
    }
}

/// Maps a borrowed Leica 6-bit code to the user's real lens.
@Model
final class CodeMapping {
    var code: String // e.g. "011010"
    var leicaLensName: String // the Leica lens this code officially belongs to
    var lens: UserLens?

    init(code: String, leicaLensName: String, lens: UserLens? = nil) {
        self.code = code
        self.leicaLensName = leicaLensName
        self.lens = lens
    }
}
