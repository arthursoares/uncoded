import Foundation

/// A journal as stored: the record and the file holding it.
struct JournalRecord {
    let journal: WriteJournal
    let url: URL
}

/// One pass over the journal directory. Files that would not decode are kept
/// separately: a corrupt journal must never read as "this file was never
/// fixed", which would hide a revert the user still needs.
struct JournalIndex {
    var records: [JournalRecord] = []
    var corrupt: [URL] = []
}

/// Stores write journals in Application Support so fixes can be reverted
/// even after the app restarts.
struct JournalStore: Sendable {
    let directory: URL

    /// The store the app uses. Tests build their own with a temp directory.
    static let `default` = JournalStore(directory: JournalStore.defaultDirectory)

    static var defaultDirectory: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Uncoded/Journals", isDirectory: true)
    }

    /// Where the shared store keeps its journals (shown in Settings).
    static var directory: URL { `default`.directory }

    static func fixedPaths() -> Set<String> { `default`.fixedPaths() }

    static func journal(for file: URL) -> JournalRecord? { `default`.journal(for: file) }

    // MARK: - Reading

    /// Reads and decodes the whole directory once. Every question below is
    /// answered from one index, so a scan of 500 frames doesn't re-decode the
    /// journals 500 times.
    func index() -> JournalIndex {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        else { return JournalIndex() }

        var index = JournalIndex()
        for url in items where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let journal = try? JSONDecoder().decode(WriteJournal.self, from: data)
            else {
                index.corrupt.append(url)
                continue
            }
            index.records.append(JournalRecord(journal: journal, url: url))
        }
        return index
    }

    /// What a stored journal means for the file it names.
    enum Resolution: Equatable {
        /// The write is on disk (or the journal predates the pending split).
        case landed
        /// The journal describes a write that never reached the file.
        case abandoned
        /// The file is gone, unreadable, or in neither state — say nothing and
        /// keep the record; it is the only way back if it *did* half-land.
        case unverified
    }

    /// A pending journal describes a write that may or may not have reached
    /// disk — the app can die between saving the record and committing. The
    /// file's own bytes are the only honest answer.
    func resolve(_ record: JournalRecord) -> Resolution {
        guard !record.journal.isCommitted else { return .landed }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: record.journal.filePath),
                                   options: .mappedIfSafe)
        else { return .unverified }
        if record.journal.describesWrittenBytes(data) { return .landed }
        if record.journal.describesOriginalBytes(data) { return .abandoned }
        return .unverified
    }

    /// Paths of all files that currently have a journal on disk — used to
    /// restore FIXED seals (and revert access) after rescans and relaunches.
    /// Pending journals whose write never landed are not fixes, and are pruned.
    func fixedPaths() -> Set<String> {
        var paths = Set<String>()
        for record in index().records {
            switch resolve(record) {
            case .landed:
                if !record.journal.isCommitted { try? finalize(record) }
                paths.insert(record.journal.filePath)
            case .unverified:
                paths.insert(record.journal.filePath)
            case .abandoned:
                try? FileManager.default.removeItem(at: record.url)
            }
        }
        return paths
    }

    /// What a lookup found, including the parts worth reporting: journal files
    /// belonging to this file that could not be read, and whether the match
    /// came from the file's content rather than its path.
    struct Lookup {
        var record: JournalRecord?
        var corrupt: [URL] = []
        var matchedByContent = false
    }

    /// The most recent journal recorded for a file, if any.
    func journal(for file: URL) -> JournalRecord? { lookup(for: file).record }

    /// Finds a file's journal by path, falling back to its content: a fixed
    /// file that Lightroom renamed on import has no journal at its new path,
    /// but the bytes the write left behind still identify it.
    func lookup(for file: URL) -> Lookup {
        let index = index()
        var result = Lookup()
        result.record = index.records
            .filter { $0.journal.filePath == file.path && resolve($0) != .abandoned }
            .max { $0.journal.date < $1.journal.date }
        if result.record == nil, let claim = journalClaiming(file, in: index) {
            result.record = claim
            result.matchedByContent = true
        }
        // Corrupt files can't be read, so only their name says who they belong
        // to — which is why the name starts with the frame's filename.
        let prefix = file.lastPathComponent + "-"
        result.corrupt = index.corrupt.filter { $0.lastPathComponent.hasPrefix(prefix) }
        return result
    }

    /// The newest journal whose written state matches this file's bytes exactly
    /// — regardless of the path either of them thinks it has.
    func journalClaiming(_ file: URL, in index: JournalIndex? = nil) -> JournalRecord? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return (index ?? self.index()).records
            .filter { $0.journal.describesWrittenBytes(data) }
            .max { $0.journal.date < $1.journal.date }
    }

    // MARK: - Writing

    /// Writes a journal to its own file. The UUID matters: two same-named files
    /// fixed within one second used to overwrite each other's undo record.
    func save(_ journal: WriteJournal) throws -> JournalRecord {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: journal.date)
            .replacingOccurrences(of: ":", with: "-")
        let name = "\(journal.fileName)-\(stamp)-\(UUID().uuidString).json"
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        return JournalRecord(journal: journal, url: url)
    }

    /// Marks a saved journal as committed, now that the write is on disk.
    func finalize(_ record: JournalRecord) throws {
        var journal = record.journal
        journal.state = .committed
        try JSONEncoder().encode(journal).write(to: record.url, options: .atomic)
    }

    func remove(_ record: JournalRecord) {
        try? FileManager.default.removeItem(at: record.url)
    }
}

/// Applies and reverts lens fixes: optional .bak copy, native write, journal.
struct Fixer: Sendable {
    let store: JournalStore

    init(store: JournalStore = .default) {
        self.store = store
    }

    static let `default` = Fixer()

    struct FixError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A fix that landed, plus anything worth saying about it. A write that
    /// reached the file is never reported as a failure — at most as a success
    /// with a warning about the undo record or the backup.
    struct FixOutcome {
        var warnings: [String] = []
    }

    @discardableResult
    static func fix(file: URL, with write: LensWrite, keepBak: Bool) throws -> FixOutcome {
        try `default`.fix(file: file, with: write, keepBak: keepBak)
    }

    static func revert(file: URL) throws { try `default`.revert(file: file) }

    /// Fixes one file. With `keepBak`, a sibling .bak copy is made first
    /// (never overwriting an existing one — the oldest backup is the one
    /// that predates any of our writes).
    @discardableResult
    func fix(file: URL, with write: LensWrite, keepBak: Bool) throws -> FixOutcome {
        var outcome = FixOutcome()

        // Plan before touching anything: the journal has to exist before the
        // bytes move, and the planned patches are also what tells us whether an
        // existing .bak is a faithful copy of this file as it is now.
        let prepared = try TIFFWriter.prepare(write, to: file)
        let index = store.index()

        // A fixed file that was renamed after the fix scans as unfixed. Fixing
        // it again would append a second copy of everything and copy
        // already-fixed bytes into the .bak, so refuse and point at the revert.
        if let claim = store.journalClaiming(file, in: index),
           claim.journal.filePath != file.path {
            throw FixError(message: """
            \(file.lastPathComponent) was already fixed by Uncoded (as \
            \(claim.journal.fileName)) and renamed or moved since. Revert it \
            instead of fixing it twice — fixing again would write a second copy \
            of the lens metadata and back up the already-fixed file.
            """)
        }

        var createdBak: URL?
        if keepBak {
            let bak = file.appendingPathExtension("bak")
            if FileManager.default.fileExists(atPath: bak.path) {
                if let warning = staleBakWarning(bak, file: file, planned: prepared.journal, index: index) {
                    outcome.warnings.append(warning)
                }
            } else {
                try checkSpaceForBak(of: file)
                try FileManager.default.copyItem(at: file, to: bak)
                createdBak = bak
            }
        }

        // The undo record goes down BEFORE the bytes change. A crash — or a
        // full disk — in between must leave a modified file with a journal,
        // never a modified file nobody can undo. It is saved pending; the
        // file's bytes decide later whether the write actually landed.
        var journal = prepared.journal
        journal.bak = createdBak.flatMap(Self.bakRecord)
        var record: JournalRecord?
        do {
            record = try store.save(journal)
        } catch {
            // No record is bad, but refusing a fix the user asked for because
            // Application Support is unwritable is worse than saying so.
            outcome.warnings.append("""
            Could not save the undo record for \(file.lastPathComponent) \
            (\(error.localizedDescription)). The fix was applied, but Revert is \
            not available for this file.
            """)
        }

        do {
            try prepared.commit()
        } catch {
            // A commit fails either before writing anything (file changed, not
            // writable) or part-way through. Only when the file is provably
            // still pristine may the undo record and our own .bak go away —
            // otherwise they are the only way back.
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
               prepared.journal.describesOriginalBytes(data) {
                if let record { store.remove(record) }
                if let createdBak { try? FileManager.default.removeItem(at: createdBak) }
            }
            throw error
        }

        // Failing here is harmless and must not turn a landed write into an
        // error: a pending journal is resolved against the file's bytes.
        if let record { try? store.finalize(record) }
        return outcome
    }

    /// Reverts a file to its pre-Uncoded state and removes the journals it
    /// consumed. Re-fixing a frame stacks journals, so popping only the newest
    /// would leave the previous lens written while the UI reports a full
    /// revert — the stack is drained instead. Every step verifies the bytes it
    /// is about to restore, so a chain that stops verifying stops here.
    func revert(file: URL) throws {
        let first = store.lookup(for: file)
        guard var record = first.record else {
            if !first.corrupt.isEmpty {
                throw FixError(message: """
                \(file.lastPathComponent) has an undo record, but it is \
                unreadable (\(first.corrupt.count) corrupt journal file(s) in \
                \(store.directory.path)). Restore the .bak copy instead.
                """)
            }
            throw FixError(message: "No undo journal found for \(file.lastPathComponent)")
        }

        var consumed = Set<URL>()
        var undone = 0
        while true {
            do {
                try TIFFWriter.revert(record.journal.relocated(to: file))
            } catch {
                guard undone > 0 else { throw error }
                throw FixError(message: """
                Undid the most recent fix on \(file.lastPathComponent), but an \
                earlier one could not be undone: \(error.localizedDescription)
                """)
            }
            store.remove(record)
            consumed.insert(record.url)
            undone += 1
            guard let next = store.lookup(for: file).record, !consumed.contains(next.url) else { break }
            record = next
        }
    }

    // MARK: - Backup copy

    /// An existing .bak is never overwritten — it predates our writes, which is
    /// what makes it the pristine copy. But it may also be a copy of a version
    /// of the file that no longer exists (something edited the file between two
    /// fixes), and silently presenting that as "the backup" is how a restore
    /// quietly throws work away. So: always keep it, and say when it no longer
    /// matches the file.
    private func staleBakWarning(_ bak: URL, file: URL, planned: WriteJournal,
                                 index: JournalIndex) -> String? {
        // Does it still match the file as it stands? The comparison covers the
        // length and every region this fix is about to change — which is where
        // a develop-settings or metadata edit lands.
        if let data = try? Data(contentsOf: bak, options: .mappedIfSafe),
           planned.describesOriginalBytes(data) {
            return nil
        }
        if let record = Self.bakRecord(bak),
           let ours = index.records.first(where: { $0.journal.bak?.matches(record) == true }) {
            let when = DateFormatter.localizedString(from: ours.journal.date,
                                                     dateStyle: .medium, timeStyle: .short)
            return """
            \(bak.lastPathComponent) is the copy Uncoded made before the fix on \
            \(when), and \(file.lastPathComponent) has changed since. It is kept \
            as the pristine original, so restoring it would discard those later \
            changes — use Revert for the lens metadata instead.
            """
        }
        return """
        \(bak.lastPathComponent) already exists but is not a backup of \
        \(file.lastPathComponent) as it is now — Uncoded left it untouched \
        rather than replace it. Move it aside if you want a fresh backup.
        """
    }

    /// A .bak is a full-size copy of a raw file. Without room for it the copy
    /// fails part-way and leaves a truncated file that looks like a backup.
    private func checkSpaceForBak(of file: URL) throws {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let free = try? file.deletingLastPathComponent()
                  .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                  .volumeAvailableCapacityForImportantUsage
        else { return }
        guard free >= Int64(size) else {
            let needed = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            throw FixError(message: """
            Not enough free space to back up \(file.lastPathComponent): the \
            copy needs \(needed) and only \(available) is free. Free up space, \
            or turn off backup copies in Settings.
            """)
        }
    }

    private static func bakRecord(_ url: URL) -> WriteJournal.BakRecord? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return WriteJournal.BakRecord(size: size, modified: modified)
    }
}
