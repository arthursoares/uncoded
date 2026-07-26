import Foundation
import Observation
import SwiftData

/// What lens a file resolves to, and how.
struct Resolution {
    let lens: UserLens?
    let isManual: Bool
}

/// Per-file fix outcome for the current session.
enum FrameFix {
    case fixed
    case failed(String)
    /// A revert that did not happen — the file changed since the fix, or its
    /// journal is gone. The bytes on disk are still ours, so the frame keeps
    /// its FIXED seal and revert stays reachable instead of stranding.
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

    /// The full, untruncated explanation, if there is one.
    var message: String? {
        switch self {
        case .fixed: return nil
        case .failed(let message), .revertRefused(let message): return message
        }
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
    var folder: URL?
    var results: [ScannedDNG] = []
    var scanning = false
    var viewMode: ScanViewMode = .sheet
    var selection = Set<URL>()
    var overrides: [URL: UserLens] = [:]
    var fixState: [URL: FrameFix] = [:]

    var busy: ScanBusy?
    var fixProgress: (done: Int, total: Int)?
    /// "12 fixed, 1 failed" — what the last batch did, until the next one.
    var lastRunSummary: String?
    var showFailuresOnly = false

    /// DNGs that were found but couldn't be read, and whether the folder
    /// itself opened at all — an empty grid means different things per case.
    var unreadableCount = 0
    var folderReadable = true

    @ObservationIgnored var batchTask: Task<Void, Never>?
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
}
