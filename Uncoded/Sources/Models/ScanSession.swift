import Foundation
import Observation

/// What lens a file resolves to, and how.
struct Resolution {
    let lens: UserLens?
    let isManual: Bool
}

/// Per-file fix outcome for the current session.
enum FrameFix {
    case fixed
    case failed(String)
}

enum ScanViewMode: String, CaseIterable {
    case sheet, list
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
    var fixing = false
}
