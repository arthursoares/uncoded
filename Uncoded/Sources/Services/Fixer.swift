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

/// Journal files this process is part way through committing. A journal is
/// saved before the write, so between the save and the commit it looks exactly
/// like the record of a write that never happened — and nothing may prune one
/// out from under a fix in progress.
final class InFlightJournals: @unchecked Sendable {
    static let shared = InFlightJournals()

    private let lock = NSLock()
    private var urls: Set<URL> = []

    func insert(_ url: URL) {
        lock.lock()
        urls.insert(url)
        lock.unlock()
    }

    func remove(_ url: URL) {
        lock.lock()
        urls.remove(url)
        lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return urls.contains(url)
    }
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

    static func sealedURLs(in candidates: [URL]) -> SealResult {
        `default`.sealedURLs(in: candidates)
    }

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

    /// Classifies pending writes after verifying patches and every present appendix byte.
    /// Commit flushes the appendix before values, then pointers. A partial appendix
    /// is recoverable only while all patches remain original. Mixed patches are
    /// recoverable at original/full length; foreign bytes always remain unverified.
    /// Committed journals stay visible even when later edits prevent safe revert.
    enum Resolution: Equatable {
        /// The write is on disk (or the journal predates the pending split).
        case landed
        /// The journal describes a write that never reached the file.
        case abandoned
        /// Some or all of the appendix reached end-of-file; none of the patches
        /// did. Truncating the fragment away restores the file.
        case abandonedWithAppendix
        /// The write stopped part way through its patches.
        case interrupted
        /// The file is gone, unreadable, or in a state we did not make — say
        /// nothing and keep the record; it is the only way back if the write
        /// *did* half-land in some way we can't see.
        case unverified

        /// The states a journal-driven restore can put right.
        var isRecoverable: Bool {
            self == .abandonedWithAppendix || self == .interrupted
        }
    }

    /// A pending journal describes a write that may or may not have reached
    /// disk — the app can die between saving the record and committing. The
    /// file's own bytes are the only honest answer.
    ///
    /// Classification only: nothing here deletes or rewrites anything. Read
    /// paths run on every scan, concurrently with fixes, and a pending journal
    /// is indistinguishable from an abandoned one until its write lands.
    func resolve(_ record: JournalRecord) -> Resolution {
        guard !record.journal.isCommitted else { return .landed }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: record.journal.filePath),
                                   options: .mappedIfSafe)
        else { return .unverified }

        let journal = record.journal
        let audit = journal.audit(data)
        guard !audit.anyForeign else { return .unverified }
        switch data.count {
        case journal.writtenLength where audit.allNew:
            return .landed
        case journal.writtenLength where audit.allOriginal:
            return journal.appendedBytes > 0 ? .abandonedWithAppendix : .abandoned
        case journal.writtenLength:
            return .interrupted
        case journal.originalLength where audit.allOriginal:
            return .abandoned
        case journal.originalLength:
            return .interrupted
        case let length where length > journal.originalLength
            && length < journal.writtenLength && audit.allOriginal:
            // An interrupted first write: audit verified the exact appendix prefix.
            return .abandonedWithAppendix
        default:
            return .unverified
        }
    }

    /// Paths of all files that currently have a journal describing a write that
    /// is on disk — used to restore FIXED seals (and revert access) after
    /// rescans and relaunches. A journal whose write never landed is not a fix,
    /// but it is left on disk: pruning belongs to the mutation paths (see
    /// `Fixer.recoverInterruptedWrite`), never to a read this can race.
    func fixedPaths(in index: JournalIndex? = nil) -> Set<String> {
        var paths = Set<String>()
        for record in (index ?? self.index()).records {
            switch resolve(record) {
            case .landed:
                if !record.journal.isCommitted, !InFlightJournals.shared.contains(record.url) {
                    try? finalize(record)
                }
                paths.insert(record.journal.filePath)
            case .unverified:
                paths.insert(record.journal.filePath)
            case .abandoned, .abandonedWithAppendix, .interrupted:
                continue
            }
        }
        return paths
    }

    /// Which of a scan's files carry a fix that can be undone.
    ///
    /// A journal recorded at a file's own path seals it directly. A file with
    /// no journal at its path is then matched by content against journals whose
    /// recorded path no longer holds what they describe — that is how a frame
    /// renamed after the fix (Lightroom's rename-on-import) keeps its seal. A
    /// copy of a file that is still fixed is deliberately *not* sealed: that
    /// journal belongs to the original, and reverting the copy would consume it
    /// (`Fixer.revert` refuses for the same reason). Nor is anything sealed
    /// when two of a scan's files answer to one journal — a seal promises an
    /// undo, and only one of them can have it.
    ///
    /// `ScanView.scan` seals `result.sealed` and keeps `result.renamedFrom` in
    /// the session, so a frame sealed by content says which filename it was
    /// fixed under.
    func sealedURLs(in candidates: [URL]) -> SealResult {
        let index = index()
        var result = SealResult()
        let sealedPaths = fixedPaths(in: index)
        for url in candidates where sealedPaths.contains(url.path) { result.sealed.insert(url) }

        let unmatched = candidates.filter { !result.sealed.contains($0) }
        guard !unmatched.isEmpty else { return result }

        // Only a journal whose own file no longer holds its content is free to
        // seal something else.
        let orphans = index.records.filter { record in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: record.journal.filePath),
                                       options: .mappedIfSafe)
            else { return true }
            return !record.journal.describesWrittenBytes(data)
        }
        guard !orphans.isEmpty else { return result }

        var matched: [(url: URL, record: JournalRecord)] = []
        var claims: [URL: Int] = [:]
        for url in unmatched {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let best = orphans.filter({ $0.journal.describesWrittenBytes(data) })
                      .max(by: { $0.journal.date < $1.journal.date })
            else { continue }
            matched.append((url, best))
            claims[best.url, default: 0] += 1
        }
        for (url, record) in matched where claims[record.url] == 1 {
            result.sealed.insert(url)
            result.renamedFrom[url] = record.journal.fileName
        }
        return result
    }

    struct SealResult {
        var sealed: Set<URL> = []
        /// For files sealed by content: the filename their journal recorded.
        var renamedFrom: [URL: String] = [:]
    }

    /// What a lookup found, including the parts worth reporting: journal files
    /// belonging to this file that could not be read, and whether the match
    /// came from the file's content rather than its path.
    struct Lookup {
        var record: JournalRecord?
        var resolution: Resolution = .unverified
        var corrupt: [URL] = []
        /// Unreadable journal files that name some other frame — a renamed
        /// file's journal is named after the old filename, so a corrupt one
        /// cannot be attributed at all.
        var unattributableCorrupt: [URL] = []
        var matchedByContent = false
    }

    /// The most recent journal recorded for a file, if any.
    func journal(for file: URL) -> JournalRecord? { lookup(for: file).record }

    /// Finds a file's journal by path, falling back to its content: a fixed
    /// file that Lightroom renamed on import has no journal at its new path,
    /// but the bytes the write left behind still identify it. An abandoned
    /// journal is not a fix and never matched; one whose appendix landed is,
    /// so the caller can clean it up.
    func lookup(for file: URL) -> Lookup {
        let index = index()
        var result = Lookup()
        let atPath = index.records
            .filter { $0.journal.filePath == file.path }
            .map { (record: $0, resolution: resolve($0)) }
            .filter { $0.resolution != .abandoned }
        if let best = atPath.max(by: { $0.record.journal.date < $1.record.journal.date }) {
            result.record = best.record
            result.resolution = best.resolution
        } else if let claim = journalClaiming(file, in: index) {
            result.record = claim
            // The claim was verified against this file's bytes, whatever state
            // the path the journal names is in.
            result.resolution = .landed
            result.matchedByContent = true
        }
        // Corrupt files can't be read, so only their name says who they belong
        // to — which is why the name starts with the frame's filename.
        let prefix = file.lastPathComponent + "-"
        for url in index.corrupt {
            if url.lastPathComponent.hasPrefix(prefix) {
                result.corrupt.append(url)
            } else {
                result.unattributableCorrupt.append(url)
            }
        }
        return result
    }

    /// The journal whose written state matches this file's bytes — a journal
    /// for this very path first, since a re-fixed frame and a copy of it can
    /// both claim the same content and only one of them is this file's own.
    func journalClaiming(_ file: URL, in index: JournalIndex? = nil) -> JournalRecord? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let claims = (index ?? self.index()).records.filter { $0.journal.describesWrittenBytes(data) }
        let newest = { (records: [JournalRecord]) in records.max { $0.journal.date < $1.journal.date } }
        return newest(claims.filter { $0.journal.filePath == file.path }) ?? newest(claims)
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

    /// Deletes a consumed or abandoned journal. Failure is reported: a journal
    /// that survives a revert re-seals the frame on the next scan, and the
    /// second revert then refuses a file that is already pristine.
    func remove(_ record: JournalRecord) throws {
        try FileManager.default.removeItem(at: record.url)
    }

    /// Every journal recorded for this path, oldest first.
    func records(for file: URL, in index: JournalIndex? = nil) -> [JournalRecord] {
        (index ?? self.index()).records
            .filter { $0.journal.filePath == file.path }
            .sorted { $0.journal.date < $1.journal.date }
    }
}

/// Applies and reverts lens fixes: optional .bak copy, native write, journal.
struct Fixer: Sendable {
    let store: JournalStore

    /// Resolves an installed .lcp's digest from its filename. Injectable so tests
    /// don't depend on which profiles Adobe happens to have installed.
    let profileDigest: @Sendable (String) -> String?

    init(store: JournalStore = .default,
         profileDigest: @escaping @Sendable (String) -> String?
             = { LCPIndex.cachedDigest(forProfileNamed: $0) }) {
        self.store = store
        self.profileDigest = profileDigest
    }

    static let `default` = Fixer()

    struct FixError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A fix that landed, plus anything worth saying about it. A write that
    /// reached the file is never reported as a failure — at most as a success
    /// with a warning about the backup. (Anything that would leave the write
    /// un-undoable is refused before the write instead, so it can still be
    /// thrown.) The warnings ride along on `FrameFix.fixed`, which keeps the
    /// frame's seal and marks it.
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
        let write = resolvingProfileDigest(write)

        // A fix is a mutation, so this is where the leftovers of an interrupted
        // one are cleaned up — before planning, since a stale appendix would
        // otherwise be planned around and become permanent.
        try recoverInterruptedWrite(for: file)

        // Plan before touching anything: the journal has to exist before the
        // bytes move, and the planned patches are also what tells us whether an
        // existing .bak is a faithful copy of this file as it is now.
        let prepared = try TIFFWriter.prepare(write, to: file)
        let index = store.index()

        // A fixed file that was renamed — or copied — after the fix scans as
        // unfixed. Fixing it again would append a second copy of everything and
        // copy already-fixed bytes into the .bak, so refuse and say where the
        // undo record lives.
        if let claim = store.journalClaiming(file, in: index),
           claim.journal.filePath != file.path {
            throw FixError(message: alreadyFixedMessage(file, claim: claim))
        }

        let needsBak = keepBak && !FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path)
        try checkSpace(for: file, appending: prepared.journal.appendedBytes, copying: needsBak)

        var createdBak: URL?
        if keepBak {
            let bak = file.appendingPathExtension("bak")
            if needsBak {
                try FileManager.default.copyItem(at: file, to: bak)
                createdBak = bak
            } else if let warning = staleBakWarning(bak, file: file, planned: prepared.journal, index: index) {
                outcome.warnings.append(warning)
            }
        }

        // The undo record goes down BEFORE the bytes change: a crash — or a full
        // disk — in between must leave a modified file with a journal, never a
        // modified file nobody can undo. If it can't be saved, nothing has been
        // written yet, so refusing here is both honest and safe.
        var journal = prepared.journal
        journal.bak = createdBak.flatMap(Self.bakRecord)
        let record: JournalRecord
        do {
            record = try store.save(journal)
        } catch {
            if let createdBak { try? FileManager.default.removeItem(at: createdBak) }
            throw FixError(message: """
            Uncoded could not save an undo record for \(file.lastPathComponent) \
            in \(store.directory.path) (\(error.localizedDescription)), so it \
            left the file alone rather than rewrite it with no way back.
            """)
        }

        // Until the write lands, the record looks exactly like one for a write
        // that never happened; flag it so no concurrent cleanup prunes it.
        InFlightJournals.shared.insert(record.url)
        defer { InFlightJournals.shared.remove(record.url) }

        do {
            try prepared.commit()
        } catch {
            // A commit fails either before writing anything (file changed, not
            // writable) or part-way through. Only when the file is provably
            // still pristine may the undo record and our own .bak go away —
            // otherwise they are the only way back.
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe),
               prepared.journal.describesOriginalBytes(data) {
                try? store.remove(record)
                if let createdBak { try? FileManager.default.removeItem(at: createdBak) }
            }
            throw error
        }

        // Failing here is harmless and must not turn a landed write into an
        // error: a pending journal is resolved against the file's bytes.
        try? store.finalize(record)
        return outcome
    }

    /// Fills in a digest the lens row doesn't have yet.
    ///
    /// `LensProfileBackfill` repairs the stored rows at launch, but it runs
    /// detached: a fix started seconds after launch can still be holding a lens
    /// saved by v0.1.x, and would write the very thing the backfill exists to
    /// prevent — `crs:LensProfileSetup="Custom"` beside an empty digest, a
    /// profile reference Lightroom cannot resolve. So the write resolves its own
    /// digest from the .lcp named in the row. Only an empty one: a digest that
    /// disagrees with the installed file is the backfill's business, and silently
    /// writing something other than what the UI shows would be worse.
    ///
    /// The row itself is left alone — this is a `LensWrite`, not the model, and
    /// the fix path has no business saving to the store.
    private func resolvingProfileDigest(_ write: LensWrite) -> LensWrite {
        guard write.profileDigest.isEmpty, !write.profileFilename.isEmpty,
              let digest = profileDigest(write.profileFilename), !digest.isEmpty
        else { return write }
        var healed = write
        healed.profileDigest = digest
        return healed
    }

    /// Cleans up after a fix that died mid-commit: a journal for a write that
    /// never landed is dropped, and a write that stopped part way — appendix
    /// only, or some of its patches — is rolled back to the file's pre-write
    /// bytes. Both leave the file exactly as it was before that fix. Only ever
    /// called from a path that is already about to change this file.
    private func recoverInterruptedWrite(for file: URL) throws {
        for record in store.records(for: file).reversed() {
            guard !InFlightJournals.shared.contains(record.url) else { continue }
            let resolution = store.resolve(record)
            guard resolution == .abandoned || resolution.isRecoverable else { continue }
            if resolution.isRecoverable { try restoreToOriginal(record) }
            try? store.remove(record)
        }
    }

    /// Rolls a half-written file back: the pre-write bytes at every patched
    /// region, and none of the appendix. Safe only for a journal that resolves
    /// to an incomplete write — every region proven to hold either its
    /// pre-write or its post-write bytes — which is re-checked here rather than
    /// taken on trust from the caller.
    private func restoreToOriginal(_ record: JournalRecord) throws {
        guard store.resolve(record).isRecoverable else {
            throw TIFFWriteError.fileChangedSinceFix
        }
        let url = URL(fileURLWithPath: record.journal.filePath)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for patch in record.journal.patches {
            try handle.seek(toOffset: UInt64(patch.offset))
            try handle.write(contentsOf: patch.original)
        }
        try handle.truncate(atOffset: UInt64(record.journal.originalLength))
        try handle.synchronize()
    }

    /// Wording for a file whose content another journal claims. Whether the
    /// original is still there decides what happened: a copy, or a rename.
    private func alreadyFixedMessage(_ file: URL, claim: JournalRecord) -> String {
        let origin = URL(fileURLWithPath: claim.journal.filePath)
        if let data = try? Data(contentsOf: origin, options: .mappedIfSafe),
           claim.journal.describesWrittenBytes(data) {
            return """
            \(file.lastPathComponent) is a copy of \(origin.lastPathComponent), \
            which Uncoded already fixed and which is still fixed at \
            \(origin.path). Fixing this copy again would write a second copy of \
            the lens metadata; revert \(origin.lastPathComponent) and copy it \
            again, or make the copy from a file Uncoded has not fixed.
            """
        }
        return """
        \(file.lastPathComponent) was already fixed by Uncoded (as \
        \(claim.journal.fileName)) and renamed or moved since. Revert it \
        instead of fixing it twice — fixing again would write a second copy \
        of the lens metadata and back up the already-fixed file.
        """
    }

    /// Reverts a file to its pre-Uncoded state and removes the journals it
    /// consumed. Re-fixing a frame stacks journals, so popping only the newest
    /// would leave the previous lens written while the UI reports a full
    /// revert — the stack is drained instead. Every step verifies the bytes it
    /// is about to restore, so a chain that stops verifying stops here.
    func revert(file: URL) throws {
        var lookup = store.lookup(for: file)
        guard lookup.record != nil else { throw missingJournalError(file, lookup: lookup) }

        var consumed = Set<URL>()
        var undone = 0
        while let record = lookup.record, !consumed.contains(record.url) {
            do {
                // A copy of a fixed file has the same content as the original,
                // so the content fallback can land on a journal that belongs to
                // a file still sitting there fixed. Consuming it would leave
                // that file rewritten with nothing to undo it.
                if lookup.matchedByContent { try checkOriginMoved(record, target: file) }
                if lookup.resolution.isRecoverable {
                    // Not a fix to undo but the leftovers of one that died
                    // part way: roll the file back instead.
                    try restoreToOriginal(JournalRecord(journal: record.journal.relocated(to: file),
                                                        url: record.url))
                } else {
                    try TIFFWriter.revert(record.journal.relocated(to: file))
                }
            } catch {
                guard undone > 0 else { throw error }
                throw FixError(message: """
                Undid the most recent fix on \(file.lastPathComponent), but the \
                rest could not be undone: \(error.localizedDescription)
                """)
            }
            do {
                try store.remove(record)
            } catch {
                // The bytes are back, but a journal left behind re-seals the
                // frame on the next scan and the next revert then refuses a
                // file that is already pristine. Not a clean success.
                throw FixError(message: """
                \(file.lastPathComponent) was restored, but its undo record could \
                not be deleted (\(error.localizedDescription)). The frame will \
                keep showing as fixed until \(record.url.lastPathComponent) is \
                removed from \(store.directory.path).
                """)
            }
            consumed.insert(record.url)
            undone += 1
            lookup = store.lookup(for: file)
        }
    }

    /// A journal matched by content, not by path, may only be consumed once the
    /// file it names no longer holds that content — otherwise it is this file's
    /// twin's undo record, not this file's.
    private func checkOriginMoved(_ record: JournalRecord, target: URL) throws {
        let origin = URL(fileURLWithPath: record.journal.filePath)
        guard origin.path != target.path,
              let data = try? Data(contentsOf: origin, options: .mappedIfSafe),
              record.journal.describesWrittenBytes(data)
        else { return }
        throw FixError(message: """
        \(target.lastPathComponent) has no undo record of its own — it has the \
        same content as \(origin.lastPathComponent), which Uncoded fixed and \
        which is still fixed at \(origin.path). Reverting here would use up that \
        file's undo record, so revert \(origin.lastPathComponent) instead and \
        copy it again.
        """)
    }

    private func missingJournalError(_ file: URL, lookup: JournalStore.Lookup) -> FixError {
        if !lookup.corrupt.isEmpty {
            return FixError(message: """
            \(file.lastPathComponent) has an undo record, but it is unreadable \
            (\(lookup.corrupt.count) corrupt journal file(s) in \
            \(store.directory.path)). Restore the .bak copy instead.
            """)
        }
        if !lookup.unattributableCorrupt.isEmpty {
            return FixError(message: """
            No undo journal found for \(file.lastPathComponent), but \
            \(lookup.unattributableCorrupt.count) unreadable journal file(s) sit \
            in \(store.directory.path) — one of them may be this file's, under \
            the name it had when it was fixed.
            """)
        }
        return FixError(message: "No undo journal found for \(file.lastPathComponent)")
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

    /// Space for what the fix is about to write: a full-size .bak when one is
    /// being made, and the appendix in every case. A copy that runs out of room
    /// leaves a truncated file that looks like a backup; an appendix that runs
    /// out leaves dead bytes glued to an unfixed frame.
    private func checkSpace(for file: URL, appending appendix: Int, copying backup: Bool) throws {
        var needed = Int64(max(0, appendix)) + Self.spaceHeadroom
        if backup {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            needed += Int64(size)
        }
        guard let free = try? file.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        else { return }
        guard free < needed else { return }

        let wanted = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        throw FixError(message: backup ? """
        Not enough free space to back up \(file.lastPathComponent): the copy and \
        the metadata need \(wanted) and only \(available) is free. Free up space, \
        or turn off backup copies in Settings.
        """ : """
        Not enough free space to fix \(file.lastPathComponent): the new metadata \
        needs \(wanted) and only \(available) is free. Free up space and try again.
        """)
    }

    /// A margin over the exact byte count: a write that just fits is a write
    /// that fails on the next block the filesystem needs for itself.
    private static let spaceHeadroom: Int64 = 8 * 1024 * 1024

    private static func bakRecord(_ url: URL) -> WriteJournal.BakRecord? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate
        else { return nil }
        return WriteJournal.BakRecord(size: size, modified: modified)
    }
}
