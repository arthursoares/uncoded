import SwiftUI
import SwiftData

/// Scans a folder of DNGs, shows what each file claims vs. the truth according
/// to the user's code mappings (plus per-frame manual overrides), and applies
/// the fixes with the native write engine — .bak copies per Settings, undo
/// journal always. All scan state lives in ScanSession so it survives
/// switching sidebar tabs.
struct ScanView: View {
    @Bindable var session: ScanSession

    @Query private var mappings: [CodeMapping]
    @Query(sort: \UserLens.name) private var lenses: [UserLens]
    @AppStorage("keepBakBackups") private var keepBak = true

    @State private var showPicker = false
    @State private var confirmFix = false
    @State private var fixScope = FixScope.all
    @State private var pendingRevert: ScannedDNG?
    @State private var confirmRevertMarked = false
    @State private var addLensCode: String?
    @State private var codeToMap: String?

    private enum FixScope { case all, marked }

    /// Why a frame is in the fix set — first write, rewrite after the user
    /// re-assigned an already-fixed frame, or a retry of a failed write.
    private enum FixKind { case first, refix, retry }

    private struct FixTarget {
        let file: ScannedDNG
        let lens: UserLens
        let kind: FixKind
    }

    /// One pass over the scan: what every frame resolves to, what a Fix would
    /// write, and the header counts. Built once per render so cells do O(1)
    /// lookups instead of re-walking the results.
    private struct ScanPlan {
        private(set) var resolutions: [URL: Resolution] = [:]
        private(set) var targets: [FixTarget] = [] // scan order
        private(set) var targetByURL: [URL: FixTarget] = [:]
        private(set) var codedCount = 0
        private(set) var mappedCount = 0
        private(set) var fixedCount = 0
        private(set) var failureCount = 0
        private(set) var unclaimedCodes: [String: Int] = [:]

        init(session: ScanSession, mappings: [CodeMapping]) {
            // The lens each mapped code points at. First row wins per code.
            var lensByCode: [String: UserLens] = [:]
            var seen = Set<String>()
            for mapping in mappings where seen.insert(mapping.code).inserted {
                if let lens = mapping.lens { lensByCode[mapping.code] = lens }
            }

            for file in session.results {
                let resolution: Resolution
                if let manual = session.overrides[file.url] {
                    resolution = Resolution(lens: manual, isManual: true)
                } else if let lens = file.mappedLens({ lensByCode[$0] }) {
                    // When the camera string can't say which generation it is,
                    // the codes the user mapped say which lens they engraved.
                    resolution = Resolution(lens: lens, isManual: false)
                } else {
                    resolution = Resolution(lens: nil, isManual: false)
                }
                resolutions[file.url] = resolution

                let state = session.fixState[file.url]
                if file.matchedCode != nil { codedCount += 1 }
                if resolution.lens != nil { mappedCount += 1 }
                if state?.isFixed == true { fixedCount += 1 }
                if state?.isFailure == true { failureCount += 1 }
                if let code = file.matchedCode?.code, resolution.lens == nil, state == nil {
                    unclaimedCodes[code, default: 0] += 1
                }
                if let target = Self.target(file: file, lens: resolution.lens, state: state) {
                    targets.append(target)
                    targetByURL[file.url] = target
                }
            }
        }

        /// Frames that resolve to a lens and still need a write: never fixed,
        /// a failed write worth retrying (nothing was committed), or a fixed
        /// frame whose lens no longer matches what the file claims.
        private static func target(file: ScannedDNG, lens: UserLens?,
                                   state: FrameFix?) -> FixTarget? {
            guard let lens else { return nil }
            switch state {
            case nil:
                return FixTarget(file: file, lens: lens, kind: .first)
            case .failed:
                return FixTarget(file: file, lens: lens, kind: .retry)
            case .fixed, .revertRefused:
                // The reader trims what it reads, so compare trimmed.
                let claimed = file.claimedLens?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard claimed != lens.name.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return nil
                }
                return FixTarget(file: file, lens: lens, kind: .refix)
            }
        }

        func resolution(for file: ScannedDNG) -> Resolution {
            resolutions[file.url] ?? Resolution(lens: nil, isManual: false)
        }

        /// The lens a fixed frame has since been re-assigned to, if any.
        func refixLens(for file: ScannedDNG) -> UserLens? {
            guard let target = targetByURL[file.url], target.kind == .refix else { return nil }
            return target.lens
        }

        /// The most frequent unclaimed code — the one to suggest claiming first.
        var topUnclaimedCode: (code: String, count: Int)? {
            guard let best = unclaimedCodes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })
            else { return nil }
            return (best.key, best.value)
        }
    }

    /// While the grid is filtered to failures, Fix acts on what's visible —
    /// a button that counts hidden frames would be lying.
    private func allTargets(_ plan: ScanPlan) -> [FixTarget] {
        guard session.showFailuresOnly, plan.failureCount > 0 else { return plan.targets }
        return plan.targets.filter { $0.kind == .retry }
    }

    private func markedTargets(_ plan: ScanPlan) -> [FixTarget] {
        allTargets(plan).filter { session.selection.contains($0.file.url) }
    }

    private func scopedTargets(_ plan: ScanPlan) -> [FixTarget] {
        fixScope == .marked ? markedTargets(plan) : allTargets(plan)
    }

    /// Marked frames whose bytes on disk are ours — the batch-revert set.
    private var markedReverts: [ScannedDNG] {
        session.results.filter {
            session.selection.contains($0.url) && session.fixState[$0.url]?.isFixed == true
        }
    }

    /// Frame numbers stay tied to the scan order even when the grid is
    /// filtered down to the failures.
    private func displayed(_ plan: ScanPlan) -> [(number: Int, file: ScannedDNG)] {
        let all = session.results.enumerated().map { (number: $0.offset + 1, file: $0.element) }
        // With no failures left there is no chip to switch the filter back off.
        guard session.showFailuresOnly, plan.failureCount > 0 else { return all }
        return all.filter { session.fixState[$0.file.url]?.isFailure == true }
    }

    var body: some View {
        let plan = ScanPlan(session: session, mappings: mappings)
        VStack(spacing: 0) {
            if session.results.isEmpty && !session.scanning {
                emptyState
            } else {
                resultsArea(plan)
            }
        }
        .background(Theme.bg)
        .navigationTitle("Scan")
        .toolbar {
            if !session.results.isEmpty {
                Picker("View", selection: $session.viewMode) {
                    Image(systemName: "square.grid.3x2").tag(ScanViewMode.sheet)
                    Image(systemName: "list.bullet").tag(ScanViewMode.list)
                }
                .pickerStyle(.segmented)
            }
            Button {
                showPicker = true
            } label: {
                Label("Choose Folder", systemImage: "folder")
            }
            .disabled(session.busyNow)
            .help(session.busyNow ? "Finish or stop the running batch first" : "Choose a folder of DNGs")
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { scan(url) }
        }
        .safeAreaInset(edge: .bottom) {
            if !session.selection.isEmpty { markBar }
        }
        .confirmationDialog(fixDialogTitle(plan), isPresented: $confirmFix,
                            titleVisibility: .visible) {
            Button(fixConfirmVerb(scopedTargets(plan))) { runFix(scopedTargets(plan)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(fixDialogMessage(plan))
        }
        .confirmationDialog(
            "Revert the fix on \(pendingRevert?.filename ?? "this frame")?",
            isPresented: Binding(get: { pendingRevert != nil },
                                 set: { if !$0 { pendingRevert = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revert Fix") {
                if let file = pendingRevert { runRevert([file]) }
                pendingRevert = nil
            }
            Button("Cancel", role: .cancel) { pendingRevert = nil }
        } message: {
            Text(revertMessage)
        }
        .confirmationDialog(
            "Revert \(markedReverts.count) marked fix\(markedReverts.count == 1 ? "" : "es")?",
            isPresented: $confirmRevertMarked, titleVisibility: .visible
        ) {
            Button("Revert Fixes") { runRevert(markedReverts) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(revertMessage)
        }
        .sheet(item: $addLensCode) { code in
            AddLensSheet(preselectedCode: code)
        }
        .sheet(item: $codeToMap) { code in
            MapCodeSheet(code: code, existing: mappings.first { $0.code == code })
        }
    }

    // MARK: - Empty states

    /// An empty grid has three very different causes; the pristine drop zone
    /// is only one of them.
    @ViewBuilder
    private var emptyState: some View {
        Group {
            if !session.folderReadable {
                emptyPanel(
                    icon: "lock.slash",
                    title: "Uncoded can't read that folder",
                    body: "macOS blocked access. Grant it in System Settings → Privacy & Security → Files and Folders (or Full Disk Access), then scan again.",
                    showsPrivacyButton: true)
            } else if session.unreadableCount > 0 {
                emptyPanel(
                    icon: "exclamationmark.triangle",
                    title: "\(session.unreadableCount) DNG\(session.unreadableCount == 1 ? "" : "s") found, none readable",
                    body: "The files are there but their metadata couldn't be read. Usually macOS privacy protection: System Settings → Privacy & Security → Files and Folders (or Full Disk Access). Damaged or non-Leica DNGs can also land here.",
                    showsPrivacyButton: true)
            } else if session.skippedSubfolders > 0 {
                emptyPanel(
                    icon: "folder.badge.questionmark",
                    title: "\(session.skippedSubfolders) subfolder\(session.skippedSubfolders == 1 ? "" : "s") couldn't be opened",
                    body: "No DNGs outside them, and the walk was turned away at the ones it skipped — usually macOS privacy protection: System Settings → Privacy & Security → Files and Folders (or Full Disk Access).",
                    showsPrivacyButton: true)
            } else if let folder = session.folder {
                emptyPanel(
                    icon: "magnifyingglass",
                    title: "No DNGs in \(folder.lastPathComponent)",
                    body: "Uncoded scans .dng files only — JPEG and other raw formats aren't supported. Subfolders are included.",
                    showsPrivacyButton: false)
            } else {
                dropZone
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first, !session.busyNow else { return false }
            scan(first)
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "viewfinder")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(Theme.faint)
            Text("Drop a folder of DNGs")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.engraved)
            Text("Uncoded reads only the metadata — a few KB per file —\nand never modifies anything without asking.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            Button("Choose Folder…") { showPicker = true }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
    }

    private func emptyPanel(icon: String, title: String, body: String,
                            showsPrivacyButton: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .thin))
                .foregroundStyle(Theme.rebate)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.engraved)
            if let folder = session.folder {
                Text(folder.path)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(body)
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                if showsPrivacyButton {
                    Button("Open Privacy Settings…") { openPrivacySettings() }
                        .controlSize(.small)
                }
                Button("Choose Folder…") { showPicker = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
            }
        }
    }

    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Results

    private func resultsArea(_ plan: ScanPlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                if let folder = session.folder {
                    Text(folder.path)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if session.scanning {
                    ProgressView().controlSize(.small)
                } else {
                    statsAndActions(plan)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if !session.scanning, let top = plan.topUnclaimedCode {
                unclaimedBanner(top)
            }

            Divider().overlay(Theme.panelEdge)

            switch session.viewMode {
            case .sheet:
                ContactSheet(frames: displayed(plan),
                             resolve: plan.resolution(for:),
                             fixInfo: { session.fixState[$0.url] },
                             refixLens: plan.refixLens(for:),
                             isSelected: { session.selection.contains($0.url) },
                             onTap: { toggleMark($0) },
                             onAssign: { assignMenu(for: [$0.url]) },
                             onRevert: { if !session.busyNow { pendingRevert = $0 } },
                             onMapCode: { codeToMap = $0 })
            case .list:
                List(displayed(plan), id: \.file.id) { frame in
                    ScanRow(file: frame.file, resolution: plan.resolution(for: frame.file),
                            fix: session.fixState[frame.file.url],
                            refixLens: plan.refixLens(for: frame.file))
                        .listRowSeparatorTint(Theme.panelEdge)
                        .contextMenu {
                            assignMenu(for: [frame.file.url])
                            if session.fixState[frame.file.url]?.isFixed == true {
                                Divider()
                                Button("Revert Fix…") { pendingRevert = frame.file }
                                    .disabled(session.busyNow)
                            }
                        }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func statsAndActions(_ plan: ScanPlan) -> some View {
        stat("\(session.results.count)", "frames")
        stat("\(plan.codedCount)", "coded")
        stat("\(plan.mappedCount)", "mapped")
        if plan.fixedCount > 0 {
            stat("\(plan.fixedCount)", "fixed", color: Theme.ok)
        }
        if session.unreadableCount > 0 {
            stat("\(session.unreadableCount)", "unreadable", color: Theme.rebate)
                .help("Found but not readable — check System Settings → Privacy & Security")
        }
        if session.skippedSubfolders > 0 {
            stat("\(session.skippedSubfolders)", "skipped", color: Theme.rebate)
                .help("Subfolder\(session.skippedSubfolders == 1 ? "" : "s") Uncoded couldn't open — any DNGs inside are missing from this scan. Check System Settings → Privacy & Security.")
        }
        if plan.failureCount > 0 { failureChip(plan.failureCount) }
        if let summary = session.lastRunSummary, !session.busyNow {
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
        }

        if session.busyNow {
            busyReadout
        } else {
            fixButtons(plan)
        }
    }

    /// The alarm stat: click to narrow the grid to what went wrong — and to
    /// what the Retry button can act on.
    private func failureChip(_ count: Int) -> some View {
        Button {
            session.showFailuresOnly.toggle()
        } label: {
            HStack(spacing: 5) {
                Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.accent)
                EngravedLabel("failed", color: Theme.accent)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Theme.accent.opacity(session.showFailuresOnly ? 0.26 : 0.1))
                    .overlay(Capsule().strokeBorder(
                        Theme.accent.opacity(session.showFailuresOnly ? 0.9 : 0.4), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help(session.showFailuresOnly ? "Show all frames" : "Show only the frames that failed")
    }

    @ViewBuilder
    private var busyReadout: some View {
        HStack(spacing: 10) {
            if let progress = session.fixProgress {
                EngravedLabel("\(session.busy?.verb ?? "working") \(progress.done) of \(progress.total)",
                              color: Theme.rebate)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Stop") { session.batchTask?.cancel() }
                .controlSize(.small)
                .help("Stops after the file currently being written — never mid-write")
        }
    }

    @ViewBuilder
    private func fixButtons(_ plan: ScanPlan) -> some View {
        let all = allTargets(plan)
        let marked = markedTargets(plan)
        if !marked.isEmpty {
            Button(fixLabel(marked, marked: true)) {
                fixScope = .marked
                confirmFix = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
            if all.count > marked.count {
                Button("\(verb(all)) all \(all.count)") {
                    fixScope = .all
                    confirmFix = true
                }
                .controlSize(.small)
            }
        } else if !all.isEmpty {
            Button(fixLabel(all, marked: false)) {
                fixScope = .all
                confirmFix = true
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.small)
        }
    }

    /// "Fix", "Retry" or "Rewrite" — whichever is true of the whole set.
    private func verb(_ targets: [FixTarget]) -> String {
        if targets.allSatisfy({ $0.kind == .retry }) { return "Retry" }
        if targets.allSatisfy({ $0.kind == .refix }) { return "Rewrite" }
        return "Fix"
    }

    private func fixLabel(_ targets: [FixTarget], marked: Bool) -> String {
        let count = targets.count
        if marked { return "\(verb(targets)) \(count) marked" }
        if targets.allSatisfy({ $0.kind == .retry }) { return "Retry \(count) failed" }
        return "\(verb(targets)) \(count) frame\(count == 1 ? "" : "s")"
    }

    /// The road out of the "0 mapped" dead end: an unclaimed code with a
    /// direct route to claiming it.
    private func unclaimedBanner(_ top: (code: String, count: Int)) -> some View {
        HStack(spacing: 10) {
            BitPatternView(code: top.code, dotSize: 7)
            Text("\(top.count) frame\(top.count == 1 ? "" : "s") wear\(top.count == 1 ? "s" : "") code \(top.code) — not claimed by any of your lenses yet")
                .font(.system(size: 11))
                .foregroundStyle(Theme.rebate)
            Spacer()
            if !lenses.isEmpty {
                Button("Map to a Lens…") { codeToMap = top.code }
                    .controlSize(.small)
            }
            Button("Add Lens…") { addLensCode = top.code }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.rebate.opacity(0.08))
    }

    /// Grease-pencil action bar for the marked frames.
    private var markBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                Text("\(session.selection.count) marked")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.engraved)
            }
            Spacer()
            Menu {
                assignMenu(for: session.selection)
            } label: {
                Label("Assign Lens", systemImage: "camera.aperture")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(lenses.isEmpty || session.busyNow)
            if lenses.isEmpty {
                Text("add lenses under “My Lenses” first")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }
            if !markedReverts.isEmpty {
                Button("Revert \(markedReverts.count) Marked Fix\(markedReverts.count == 1 ? "" : "es")…") {
                    confirmRevertMarked = true
                }
                .disabled(session.busyNow)
            }
            Button("Deselect") { session.selection = [] }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private func assignMenu(for urls: Set<URL>) -> some View {
        ForEach(lenses) { lens in
            Button(lens.name) { assign(lens, to: urls) }
        }
        if urls.contains(where: { session.overrides[$0] != nil }) {
            Divider()
            Button("Remove manual override") {
                for url in urls { session.overrides[url] = nil }
                session.selection = []
            }
        }
    }

    private func stat(_ value: String, _ label: String,
                      color: Color = Theme.engraved) -> some View {
        HStack(spacing: 5) {
            Text(value).font(Theme.mono(12)).foregroundStyle(color)
            EngravedLabel(label, color: color == Theme.engraved ? Theme.faint : color)
        }
    }

    private func toggleMark(_ file: ScannedDNG) {
        session.selection.formSymmetricDifference([file.url])
    }

    private func assign(_ lens: UserLens, to urls: Set<URL>) {
        for url in urls { session.overrides[url] = lens }
        session.selection = []
    }

    // MARK: - Dialog copy

    private func fixDialogTitle(_ plan: ScanPlan) -> String {
        let targets = scopedTargets(plan)
        let count = targets.count
        guard count > 0 else { return "Nothing to fix" }
        if targets.allSatisfy({ $0.kind == .retry }) {
            return "Try \(count) failed frame\(count == 1 ? "" : "s") again?"
        }
        if targets.allSatisfy({ $0.kind == .refix }) {
            return "Rewrite \(count) already-fixed frame\(count == 1 ? "" : "s")?"
        }
        return "Fix \(count) frame\(count == 1 ? "" : "s")?"
    }

    private func fixConfirmVerb(_ targets: [FixTarget]) -> String {
        if targets.allSatisfy({ $0.kind == .retry }) && !targets.isEmpty { return "Try Again" }
        if targets.allSatisfy({ $0.kind == .refix }) && !targets.isEmpty { return "Rewrite Metadata Again" }
        return "Rewrite Metadata"
    }

    private func fixDialogMessage(_ plan: ScanPlan) -> String {
        let targets = scopedTargets(plan)
        var lines: [String] = []
        let byLens = Dictionary(grouping: targets, by: { $0.lens.name })
        for (name, group) in byLens.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name) — \(group.count) frame\(group.count == 1 ? "" : "s")")
        }
        let refixes = targets.filter { $0.kind == .refix }.count
        if refixes > 0 && refixes < targets.count {
            lines.append("\(refixes) of them \(refixes == 1 ? "was" : "were") already fixed and will be rewritten with the newly assigned lens.")
        }
        let retries = targets.filter { $0.kind == .retry }.count
        if retries > 0 && retries < targets.count {
            lines.append("\(retries) of them failed earlier and \(retries == 1 ? "is" : "are") being tried again — a failed write leaves the file untouched.")
        }
        lines.append(keepBak
            ? "Lens metadata is rewritten in place. A one-time .bak copy is kept next to each file, and every fix records an undo journal."
            : "Lens metadata is rewritten in place. No .bak copies (per Settings) — every fix still records an undo journal.")
        lines.append("Photos already in a Lightroom catalog need Metadata → Read Metadata from File afterwards; photos imported after fixing just work.")
        return lines.joined(separator: "\n")
    }

    private var revertMessage: String {
        (keepBak
            ? "The original lens metadata is restored from the undo journal, in place. Any .bak copy is left untouched."
            : "The original lens metadata is restored from the undo journal, in place. No .bak copies were made (per Settings), so the journal is the only route back.")
        + " If the file changed since Uncoded fixed it, the revert is refused rather than risked."
    }

    // MARK: - Fix / revert

    private func runFix(_ targets: [FixTarget]) {
        guard !targets.isEmpty, !session.busyNow else { return }
        let work = targets.map { ($0.file.url, $0.lens.lensWrite) }
        let bak = keepBak
        // The failures filter is left alone: retrying from it drains the list,
        // and displayed() drops the filter once nothing is failing.
        session.lastRunSummary = nil
        session.busy = .fixing
        session.fixProgress = (0, work.count)
        session.batchTask = Task {
            var fixed = 0
            var warned = 0
            var failed = 0
            var stopped = false
            for (index, item) in work.enumerated() {
                // Cancellation lands between files — a write is never interrupted.
                if Task.isCancelled {
                    stopped = true
                    break
                }
                let (url, write) = item
                let outcome: FrameFix = await Task.detached(priority: .userInitiated) {
                    do {
                        let result = try Fixer.fix(file: url, with: write, keepBak: bak)
                        return .fixed(warnings: result.warnings)
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }.value
                session.fixState[url] = outcome
                if case .fixed(let warnings) = outcome {
                    fixed += 1
                    // The write landed; the warning is about the .bak beside
                    // it. Counted apart so the summary doesn't imply a failure.
                    if !warnings.isEmpty { warned += 1 }
                    await refresh(url)
                } else {
                    failed += 1
                }
                session.fixProgress = (index + 1, work.count)
            }
            finish(summary: summary(done: fixed, doneVerb: "fixed",
                                    doneNote: warned > 0 ? "\(warned) with warnings" : nil,
                                    problems: failed, problemVerb: "failed",
                                    skipped: stopped ? work.count - fixed - failed : 0))
        }
    }

    private func runRevert(_ files: [ScannedDNG]) {
        guard !files.isEmpty, !session.busyNow else { return }
        let urls = files.map(\.url)
        session.busy = .reverting
        session.fixProgress = (0, urls.count)
        session.lastRunSummary = nil
        session.batchTask = Task {
            var reverted = 0
            var refused = 0
            var stopped = false
            for (index, url) in urls.enumerated() {
                if Task.isCancelled {
                    stopped = true
                    break
                }
                // A refused or failed revert means the file is still fixed —
                // keep the seal and the message instead of stranding the frame.
                let outcome: FrameFix? = await Task.detached(priority: .userInitiated) {
                    do {
                        try Fixer.revert(file: url)
                        return nil
                    } catch {
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            return .revertRefused("This file is missing — moved, renamed, or on a volume that isn't mounted. Put it back (or rescan) and revert again.")
                        }
                        return .revertRefused(error.localizedDescription)
                    }
                }.value
                session.fixState[url] = outcome
                if outcome == nil {
                    reverted += 1
                    await refresh(url)
                } else {
                    refused += 1
                }
                session.fixProgress = (index + 1, urls.count)
            }
            finish(summary: summary(done: reverted, doneVerb: "reverted",
                                    problems: refused, problemVerb: "refused",
                                    skipped: stopped ? urls.count - reverted - refused : 0))
        }
    }

    private func finish(summary: String) {
        session.busy = nil
        session.fixProgress = nil
        session.lastRunSummary = summary
        session.batchTask = nil
    }

    /// "12 fixed (2 with warnings), 1 failed" / "3 reverted, 2 refused" — the
    /// batch's own words.
    private func summary(done: Int, doneVerb: String, doneNote: String? = nil,
                         problems: Int, problemVerb: String, skipped: Int) -> String {
        var parts = ["\(done) \(doneVerb)" + (doneNote.map { " (\($0))" } ?? "")]
        if problems > 0 { parts.append("\(problems) \(problemVerb)") }
        if skipped > 0 { parts.append("\(skipped) not attempted") }
        return parts.joined(separator: ", ")
    }

    /// Re-reads one file's metadata so the frame reflects what's on disk now.
    private func refresh(_ url: URL) async {
        let updated: ScannedDNG? = await Task.detached(priority: .userInitiated) {
            guard let meta = try? TIFFReader.read(url: url) else { return nil }
            return ScannedDNG(url: url, meta: meta,
                              codeCandidates: SixBitTable.matchCandidates(lensModel: meta.lensModel))
        }.value
        guard let updated, let index = session.results.firstIndex(where: { $0.url == url }) else { return }
        session.results[index] = updated
    }

    private func scan(_ url: URL) {
        guard !session.busyNow else { return }
        session.folder = url
        session.scanning = true
        session.results = []
        session.selection = []
        session.overrides = [:]
        session.fixState = [:]
        session.unreadableCount = 0
        session.skippedSubfolders = 0
        session.folderReadable = true
        session.showFailuresOnly = false
        session.lastRunSummary = nil
        Task {
            let (outcome, journaled) = await Task.detached(priority: .userInitiated) {
                (DNGScanner.scan(folder: url), JournalStore.fixedPaths())
            }.value
            session.results = outcome.files
            session.unreadableCount = outcome.unreadable
            session.skippedSubfolders = outcome.skippedSubfolders
            session.folderReadable = outcome.folderReadable
            // Files with a persisted journal were fixed in an earlier session —
            // restore their FIXED seals so revert stays reachable.
            for file in outcome.files where journaled.contains(file.url.path) {
                session.fixState[file.url] = .fixed(warnings: [])
            }
            session.scanning = false
        }
    }
}

// MARK: - Contact sheet

/// The scan as a film contact sheet: black frames on a dark ground, with the
/// filename and code printed beneath each frame like edge markings on the
/// rebate of a strip of film. Clicking a frame marks it, grease-pencil style.
private struct ContactSheet<AssignMenu: View>: View {
    let frames: [(number: Int, file: ScannedDNG)]
    let resolve: (ScannedDNG) -> Resolution
    let fixInfo: (ScannedDNG) -> FrameFix?
    let refixLens: (ScannedDNG) -> UserLens?
    let isSelected: (ScannedDNG) -> Bool
    let onTap: (ScannedDNG) -> Void
    @ViewBuilder let onAssign: (ScannedDNG) -> AssignMenu
    let onRevert: (ScannedDNG) -> Void
    let onMapCode: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 260), spacing: 14)],
                      spacing: 16) {
                ForEach(frames, id: \.file.id) { frame in
                    let file = frame.file
                    FrameCell(file: file,
                              frameNumber: frame.number,
                              resolution: resolve(file),
                              fix: fixInfo(file),
                              refixLens: refixLens(file),
                              selected: isSelected(file))
                        .onTapGesture { onTap(file) }
                        .contextMenu {
                            onAssign(file)
                            if fixInfo(file)?.isFixed == true {
                                Divider()
                                Button("Revert Fix…") { onRevert(file) }
                            } else if let code = file.matchedCode?.code, resolve(file).lens == nil {
                                Divider()
                                Button("Map Code \(code) to a Lens…") { onMapCode(code) }
                            }
                        }
                }
            }
            .padding(16)
        }
        .background(Color.black.opacity(0.35))
    }
}

private struct FrameCell: View {
    let file: ScannedDNG
    let frameNumber: Int
    let resolution: Resolution
    let fix: FrameFix?
    let refixLens: UserLens?
    let selected: Bool

    @State private var image: NSImage?

    private var warnings: [String] { fix?.warnings ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Color.black)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 22, weight: .thin))
                        .foregroundStyle(Theme.faint)
                }
            }
            .frame(height: 132)
            .clipped()

            // Rebate: frame number + filename as edge print, code as pits.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(String(format: "%02d", frameNumber))
                        .font(Theme.mono(9))
                        .foregroundStyle(selected ? Theme.engraved : Theme.rebate)
                        .padding(.horizontal, selected ? 4 : 0)
                        .background(
                            Capsule().stroke(Theme.accent, lineWidth: selected ? 1.5 : 0)
                        )
                    Text(file.filename)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.rebate.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let code = file.matchedCode {
                        BitPatternView(code: code.code, dotSize: 5)
                    }
                }

                status
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black)
        }
        .overlay(
            Rectangle().strokeBorder(selected ? Theme.accent : Theme.panelEdge.opacity(0.6),
                                     lineWidth: selected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .help(helpText)
        .task { image = await ThumbnailLoader.thumbnail(for: file.url) }
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch fix {
            case .fixed, .revertRefused:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.ok)
                    Text(file.claimedLens ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.ok)
                        .lineLimit(1)
                    EngravedLabel("fixed", color: Theme.ok)
                    // The write landed; something about the backup beside it
                    // did not. A tick, not an alarm.
                    if !warnings.isEmpty {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.rebate)
                    }
                }
                if !warnings.isEmpty {
                    Text(warnings.joined(separator: "\n"))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.rebate)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .revertRefused(let message) = fix {
                    EngravedLabel("revert refused", color: Theme.rebate)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.rebate)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let refixLens {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.rebate)
                        Text(refixLens.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.rebate)
                            .lineLimit(1)
                        EngravedLabel("re-fix", color: Theme.rebate)
                    }
                }
            case .failed(let message):
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.accent)
                    EngravedLabel("failed", color: Theme.accent)
                }
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                HStack(spacing: 4) {
                    if let lens = resolution.lens {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.ok)
                        Text(lens.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.ok)
                            .lineLimit(1)
                        if resolution.isManual {
                            EngravedLabel("manual", color: Theme.rebate)
                        }
                    } else if file.matchedCode != nil {
                        Text("code not mapped")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.faint)
                    } else {
                        Text(file.claimedLens ?? "no lens metadata")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var helpText: String {
        var lines = [file.filename]
        if let claimed = file.claimedLens { lines.append("claims: \(claimed)") }
        if let code = file.matchedCode { lines.append("code \(code.code) — \(code.lensName)") }
        if let lens = resolution.lens {
            lines.append("actually: \(lens.name)\(resolution.isManual ? " (manual)" : "")")
        }
        switch fix {
        case .fixed(let warnings):
            lines.append("fixed — right-click to revert")
            lines.append(contentsOf: warnings)
        case .revertRefused(let message):
            lines.append("still fixed; revert refused: \(message)")
            lines.append("right-click to try the revert again")
        case .failed(let message):
            lines.append("fix failed: \(message)")
            lines.append("the file was left untouched — mark this frame to try again")
        case nil:
            break
        }
        if let refixLens {
            lines.append("re-assigned to \(refixLens.name) — Fix rewrites this frame")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - List rows

private struct ScanRow: View {
    let file: ScannedDNG
    let resolution: Resolution
    let fix: FrameFix?
    let refixLens: UserLens?

    private var warnings: [String] { fix?.warnings ?? [] }

    var body: some View {
        HStack(spacing: 14) {
            Text(file.filename)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.engraved)
                .frame(width: 150, alignment: .leading)

            if let code = file.matchedCode {
                BitPatternView(code: code.code, dotSize: 7)
                    .help("Borrowed code \(code.code) — \(code.lensName)")
            } else {
                Color.clear.frame(width: 60, height: 7)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(file.claimedLens ?? "no lens metadata")
                    .font(.system(size: 11))
                    .foregroundStyle(file.claimedLens == nil ? Theme.faint : Theme.dim)
                    .lineLimit(1)

                switch fix {
                case .fixed, .revertRefused:
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.ok)
                        EngravedLabel("fixed", color: Theme.ok)
                        // The write landed; the backup beside it is the worry.
                        if !warnings.isEmpty {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.rebate)
                            Text(warnings.joined(separator: "\n"))
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.rebate)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if case .revertRefused(let message) = fix {
                        HStack(spacing: 5) {
                            EngravedLabel("revert refused", color: Theme.rebate)
                            Text(message)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.rebate)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let refixLens {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.rebate)
                            Text(refixLens.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.rebate)
                                .lineLimit(1)
                            EngravedLabel("re-fix", color: Theme.rebate)
                        }
                    }
                case .failed(let message):
                    HStack(spacing: 5) {
                        EngravedLabel("failed", color: Theme.accent)
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case nil:
                    if let lens = resolution.lens {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.ok)
                            Text(lens.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.ok)
                                .lineLimit(1)
                            if resolution.isManual {
                                EngravedLabel("manual", color: Theme.rebate)
                            }
                        }
                    } else if file.matchedCode != nil {
                        Text("code not mapped to one of your lenses")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}
