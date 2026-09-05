import Foundation
import Observation
import SwiftData

/// What lens a file resolves to, and how.
struct Resolution {
    let lens: UserLens?
    let isManual: Bool
    /// True when the file's own metadata already claims this lens.
    var isClaimed = false
}

/// Per-file fix outcome for the current session.
enum FrameFix {
    case fixed(warnings: [String])
    case failed(String)
    case revertRefused(String)

    /// True while the bytes on disk carry our write.
    var isFixed: Bool {
        switch self {
        case .fixed, .revertRefused: return true
        case .failed: return false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var warnings: [String] {
        if case .fixed(let warnings) = self { return warnings }
        return []
    }
}

enum ScanViewMode: String, CaseIterable {
    case sheet, list
}

/// What a running batch is doing — drives the header readout and locks the
/// controls that would pull the rug out from under it.
enum ScanBusy {
    case fixing, reverting

    var verb: String {
        switch self {
        case .fixing: return "fixing"
        case .reverting: return "reverting"
        }
    }
}

extension Notification.Name {
    /// Posted with the lens's `PersistentIdentifier` just before it is deleted,
    /// so live scan state can let go of it before SwiftData invalidates it.
    static let uncodedLensWillDelete = Notification.Name("UncodedLensWillDelete")
}

/// The scan's state, owned above the sidebar switcher so navigating away
/// from the Scan tab and back doesn't clear the opened folder.
@Observable
final class ScanSession {
    struct ScanResult: Sendable {
        var outcome: DNGScanner.Outcome
        var sealed: Set<URL> = []
        var renamedFrom: [URL: String] = [:]
    }

    typealias ScanOperation = @Sendable (URL) async -> ScanResult

    var folder: URL?
    var results: [ScannedDNG] = []
    var scanning = false
    var viewMode: ScanViewMode = .sheet
    var selection = Set<URL>()
    var overrides: [URL: UserLens] = [:]
    var fixState: [URL: FrameFix] = [:]
    /// Frames sealed by content rather than by path, and the filename their
    /// journal recorded — a fix that Lightroom renamed on import can then say
    /// so instead of looking like it belongs to a file that no longer exists.
    var renamedFrom: [URL: String] = [:]

    var busy: ScanBusy?
    var fixProgress: (done: Int, total: Int)?
    /// "12 fixed, 1 failed" — what the last batch did, until the next one.
    var lastRunSummary: String?
    var showFailuresOnly = false

    /// DNGs that were found but couldn't be read, subfolders the walk had to
    /// skip, and whether the folder itself opened at all — an empty grid, and
    /// a full one, mean different things per case.
    var unreadableCount = 0
    var skippedSubfolders = 0
    var folderReadable = true

    @ObservationIgnored var batchTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var lensDeletionObserver: NSObjectProtocol?

    var busyNow: Bool { busy != nil }

    init() {
        lensDeletionObserver = NotificationCenter.default.addObserver(
            forName: .uncodedLensWillDelete, object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.object as? PersistentIdentifier else { return }
            self?.dropOverrides(forLens: id)
        }
    }

    deinit {
        scanTask?.cancel()
        batchTask?.cancel()
        if let lensDeletionObserver {
            NotificationCenter.default.removeObserver(lensDeletionObserver)
        }
    }

    /// Overrides hold SwiftData objects; a deleted lens must not stay live in
    /// the scan or `resolve` would hand an invalidated model to the writer.
    func dropOverrides(forLens id: PersistentIdentifier) {
        let stale = overrides.filter { $0.value.persistentModelID == id }.map(\.key)
        guard !stale.isEmpty else { return }
        for url in stale { overrides[url] = nil }
        selection.subtract(stale)
    }

    @discardableResult
    @MainActor
    func scan(_ url: URL) -> Task<Void, Never>? {
        scan(url, using: { url in await Self.performScan(url) })
    }

    @discardableResult
    @MainActor
    func scan(_ url: URL, using operation: @escaping ScanOperation) -> Task<Void, Never>? {
        guard !busyNow else { return nil }

        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask?.cancel()
        prepareToScan(url)

        let task = Task { [weak self] in
            let result = await operation(url)
            guard let self, self.scanGeneration == generation else { return }
            self.commit(result)
            self.scanTask = nil
        }
        scanTask = task
        return task
    }

    @MainActor
    private func prepareToScan(_ url: URL) {
        folder = url
        scanning = true
        results = []
        selection = []
        overrides = [:]
        fixState = [:]
        renamedFrom = [:]
        unreadableCount = 0
        skippedSubfolders = 0
        folderReadable = true
        showFailuresOnly = false
        lastRunSummary = nil
    }

    @MainActor
    private func commit(_ result: ScanResult) {
        results = result.outcome.files
        unreadableCount = result.outcome.unreadable
        skippedSubfolders = result.outcome.skippedSubfolders
        folderReadable = result.outcome.folderReadable
        for file in result.outcome.files where result.sealed.contains(file.url) {
            fixState[file.url] = .fixed(warnings: [])
        }
        renamedFrom = result.renamedFrom
        scanning = false
    }

    private static func performScan(_ url: URL) async -> ScanResult {
        await Task.detached(priority: .userInitiated) {
            let outcome = DNGScanner.scan(folder: url)
            let seals = JournalStore.sealedURLs(in: outcome.files.map(\.url))
            return ScanResult(outcome: outcome, sealed: seals.sealed,
                              renamedFrom: seals.renamedFrom)
        }.value
    }
}
