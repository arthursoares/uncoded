import Foundation
import SwiftData

/// A reviewed lens entry; extracting metadata never changes the lens library.
enum LensEntryImport {
    struct Selection: Identifiable, Sendable {
        var entry: ReferenceLensImporter.Entry
        var included = true
        var codes: [String] = []

        var id: UUID { entry.id }
    }

    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func validation(_ selections: [Selection], lenses: [UserLens], mappings: [CodeMapping]) -> String? {
        let selected = selections.filter(\.included)
        guard !selected.isEmpty else { return "Select at least one lens to import." }
        var names = Set<String>()
        var codes = Set<String>()
        for selection in selected {
            let entry = selection.entry
            let key = nameKey(entry.name)
            guard !key.isEmpty else { return "Give each selected lens a name." }
            guard names.insert(key).inserted else {
                return "More than one selected entry is named \(entry.name). Choose one variant or give them distinct names."
            }
            guard !lenses.contains(where: { nameKey($0.name) == key }) else {
                return "\(entry.name) is already in My Lenses. Deselect it or give this entry a distinct name."
            }
            for (text, prefix, suffix, label) in [
                (entry.focalLength, "", "mm", "focal length"),
                (entry.aperture, "f/", "", "aperture")
            ] where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let value = Double(text.lowercased().replacingOccurrences(of: prefix, with: "")
                    .replacingOccurrences(of: suffix, with: "").trimmingCharacters(in: .whitespacesAndNewlines))
                guard let value, value.isFinite, value > 0 else {
                    return "Check the \(label) for \(entry.name), or leave it blank if unknown."
                }
            }
            for code in selection.codes {
                guard code.count == 6, code.allSatisfy({ $0 == "0" || $0 == "1" }) else {
                    return "Choose a valid 6-bit code for \(entry.name)."
                }
                guard codes.insert(code).inserted else { return "Two selected lenses use code \(code). Choose a different code or leave one unmapped." }
                if let existing = mappings.first(where: { $0.code == code }) {
                    return "Code \(code) is already assigned\(existing.lens.map { " to \($0.name)" } ?? ""). Choose another code or leave this lens unmapped."
                }
            }
        }
        return nil
    }

    /// Revalidate against the current store so an import cannot silently replace
    /// an existing lens or steal a code assigned since the review screen opened.
    @MainActor
    static func save(_ selections: [Selection], in context: ModelContext) throws -> Int {
        let lenses = try context.fetch(FetchDescriptor<UserLens>())
        let mappings = try context.fetch(FetchDescriptor<CodeMapping>())
        if let message = validation(selections, lenses: lenses, mappings: mappings) {
            throw Fixer.FixError(message: message)
        }

        var inserted: [UserLens] = []
        do {
            for selection in selections where selection.included {
                let entry = selection.entry
                let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
                let lens = UserLens(name: trim(entry.name), make: trim(entry.make),
                                    focalLength: trim(entry.focalLength), aperture: trim(entry.aperture),
                                    profileName: entry.profileName, profileFilename: entry.profileFilename,
                                    profileDigest: entry.profileDigest)
                context.insert(lens)
                inserted.append(lens)
                for code in selection.codes { Mappings.assign(code: code, to: lens, in: context) }
            }
            try context.save()
            return inserted.count
        } catch {
            for lens in inserted { context.delete(lens) }
            throw error
        }
    }
}
