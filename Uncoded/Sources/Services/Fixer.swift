import Foundation

/// Stores write journals in Application Support so fixes can be reverted
/// even after the app restarts.
enum JournalStore {
    /// Overridable for tests.
    nonisolated(unsafe) static var overrideDirectory: URL?

    static var directory: URL {
        overrideDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Uncoded/Journals", isDirectory: true)
    }

    static func save(_ journal: WriteJournal) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: journal.date)
            .replacingOccurrences(of: ":", with: "-")
        let name = URL(fileURLWithPath: journal.filePath).lastPathComponent + "-" + stamp + ".json"
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(journal).write(to: url)
        return url
    }

    /// The most recent journal recorded for a file, if any.
    static func journal(for file: URL) -> (journal: WriteJournal, url: URL)? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        return items
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (WriteJournal, URL)? in
                guard let data = try? Data(contentsOf: url),
                      let journal = try? JSONDecoder().decode(WriteJournal.self, from: data),
                      journal.filePath == file.path
                else { return nil }
                return (journal, url)
            }
            .max { $0.0.date < $1.0.date }
    }
}

/// Applies and reverts lens fixes: optional .bak copy, native write, journal.
enum Fixer {
    struct FixError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Fixes one file. With `keepBak`, a sibling .bak copy is made first
    /// (never overwriting an existing one — the oldest backup is the one
    /// that predates any of our writes).
    static func fix(file: URL, with write: LensWrite, keepBak: Bool) throws {
        if keepBak {
            let bak = file.appendingPathExtension("bak")
            if !FileManager.default.fileExists(atPath: bak.path) {
                try FileManager.default.copyItem(at: file, to: bak)
            }
        }
        let journal = try TIFFWriter.apply(write, to: file)
        _ = try JournalStore.save(journal)
    }

    /// Reverts the most recent fix recorded for a file and removes its journal.
    static func revert(file: URL) throws {
        guard let (journal, journalURL) = JournalStore.journal(for: file) else {
            throw FixError(message: "No undo journal found for \(file.lastPathComponent)")
        }
        try TIFFWriter.revert(journal)
        try? FileManager.default.removeItem(at: journalURL)
    }
}
