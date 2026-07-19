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

    private var mappingByCode: [String: CodeMapping] {
        Dictionary(mappings.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Frames that resolve to a lens and haven't been fixed yet.
    private var fixable: [(ScannedDNG, UserLens)] {
        session.results.compactMap { file in
            guard session.fixState[file.url] == nil, let lens = resolve(file).lens else { return nil }
            return (file, lens)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if session.results.isEmpty && !session.scanning {
                dropZone
            } else {
                resultsArea
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
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result { scan(url) }
        }
        .safeAreaInset(edge: .bottom) {
            if !session.selection.isEmpty { markBar }
        }
        .confirmationDialog(
            "Fix \(fixable.count) frame\(fixable.count == 1 ? "" : "s")?",
            isPresented: $confirmFix, titleVisibility: .visible
        ) {
            Button("Rewrite Metadata") { runFix() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(keepBak
                ? "Lens metadata is rewritten in place. A one-time .bak copy is kept next to each file, and every fix records an undo journal."
                : "Lens metadata is rewritten in place. No .bak copies (per Settings) — every fix still records an undo journal.")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            scan(first)
            return true
        }
    }

    private var resultsArea: some View {
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
                    stat("\(session.results.count)", "frames")
                    stat("\(session.results.filter { $0.matchedCode != nil }.count)", "coded")
                    stat("\(session.results.filter { resolve($0).lens != nil }.count)", "mapped")
                    let fixedCount = session.fixState.values.filter { if case .fixed = $0 { return true }; return false }.count
                    if fixedCount > 0 {
                        stat("\(fixedCount)", "fixed")
                    }
                    if session.fixing {
                        ProgressView().controlSize(.small)
                    } else if !fixable.isEmpty {
                        Button("Fix \(fixable.count) frame\(fixable.count == 1 ? "" : "s")") {
                            confirmFix = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Theme.panelEdge)

            switch session.viewMode {
            case .sheet:
                ContactSheet(results: session.results,
                             resolve: resolve,
                             fixInfo: { session.fixState[$0.url] },
                             isSelected: { session.selection.contains($0.url) },
                             onTap: { toggleMark($0) },
                             onRevert: { revert($0) })
            case .list:
                List(session.results) { file in
                    ScanRow(file: file, resolution: resolve(file), fix: session.fixState[file.url])
                        .listRowSeparatorTint(Theme.panelEdge)
                        .contextMenu {
                            assignMenu(for: [file.url])
                            if case .fixed = session.fixState[file.url] {
                                Divider()
                                Button("Revert Fix") { revert(file) }
                            }
                        }
                }
                .scrollContentBackground(.hidden)
            }
        }
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
            .disabled(lenses.isEmpty)
            if lenses.isEmpty {
                Text("add lenses under “My Lenses” first")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
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

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.engraved)
            EngravedLabel(label, color: Theme.faint)
        }
    }

    private func resolve(_ file: ScannedDNG) -> Resolution {
        if let manual = session.overrides[file.url] {
            return Resolution(lens: manual, isManual: true)
        }
        guard let code = file.matchedCode?.code, let lens = mappingByCode[code]?.lens else {
            return Resolution(lens: nil, isManual: false)
        }
        return Resolution(lens: lens, isManual: false)
    }

    private func toggleMark(_ file: ScannedDNG) {
        session.selection.formSymmetricDifference([file.url])
    }

    private func assign(_ lens: UserLens, to urls: Set<URL>) {
        for url in urls { session.overrides[url] = lens }
        session.selection = []
    }

    // MARK: - Fix / revert

    private func runFix() {
        let work = fixable.map { ($0.0.url, $0.1.lensWrite) }
        let bak = keepBak
        session.fixing = true
        Task {
            for (url, write) in work {
                let outcome: FrameFix = await Task.detached(priority: .userInitiated) {
                    do {
                        try Fixer.fix(file: url, with: write, keepBak: bak)
                        return .fixed
                    } catch {
                        return .failed(error.localizedDescription)
                    }
                }.value
                session.fixState[url] = outcome
                if case .fixed = outcome { await refresh(url) }
            }
            session.fixing = false
        }
    }

    private func revert(_ file: ScannedDNG) {
        Task {
            let error: String? = await Task.detached(priority: .userInitiated) {
                do {
                    try Fixer.revert(file: file.url)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let error {
                session.fixState[file.url] = .failed(error)
            } else {
                session.fixState[file.url] = nil
                await refresh(file.url)
            }
        }
    }

    /// Re-reads one file's metadata so the frame reflects what's on disk now.
    private func refresh(_ url: URL) async {
        let updated: ScannedDNG? = await Task.detached(priority: .userInitiated) {
            guard let meta = try? TIFFReader.read(url: url) else { return nil }
            return ScannedDNG(url: url, meta: meta,
                              matchedCode: SixBitTable.match(lensModel: meta.lensModel))
        }.value
        guard let updated, let index = session.results.firstIndex(where: { $0.url == url }) else { return }
        session.results[index] = updated
    }

    private func scan(_ url: URL) {
        session.folder = url
        session.scanning = true
        session.results = []
        session.selection = []
        session.overrides = [:]
        session.fixState = [:]
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DNGScanner.scan(folder: url)
            }.value
            session.results = found
            session.scanning = false
        }
    }
}

// MARK: - Contact sheet

/// The scan as a film contact sheet: black frames on a dark ground, with the
/// filename and code printed beneath each frame like edge markings on the
/// rebate of a strip of film. Clicking a frame marks it, grease-pencil style.
private struct ContactSheet: View {
    let results: [ScannedDNG]
    let resolve: (ScannedDNG) -> Resolution
    let fixInfo: (ScannedDNG) -> FrameFix?
    let isSelected: (ScannedDNG) -> Bool
    let onTap: (ScannedDNG) -> Void
    let onRevert: (ScannedDNG) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 260), spacing: 14)],
                      spacing: 16) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, file in
                    FrameCell(file: file,
                              frameNumber: index + 1,
                              resolution: resolve(file),
                              fix: fixInfo(file),
                              selected: isSelected(file))
                        .onTapGesture { onTap(file) }
                        .contextMenu {
                            if case .fixed = fixInfo(file) {
                                Button("Revert Fix") { onRevert(file) }
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
    let selected: Bool

    @State private var image: NSImage?

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

                HStack(spacing: 4) {
                    switch fix {
                    case .fixed:
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.ok)
                        Text(file.claimedLens ?? "")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.ok)
                            .lineLimit(1)
                        EngravedLabel("fixed", color: Theme.ok)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.accent)
                        Text(message)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    case nil:
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

    private var helpText: String {
        var lines = [file.filename]
        if let claimed = file.claimedLens { lines.append("claims: \(claimed)") }
        if let code = file.matchedCode { lines.append("code \(code.code) — \(code.lensName)") }
        if let lens = resolution.lens {
            lines.append("actually: \(lens.name)\(resolution.isManual ? " (manual)" : "")")
        }
        if case .fixed = fix { lines.append("fixed — right-click to revert") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - List rows

private struct ScanRow: View {
    let file: ScannedDNG
    let resolution: Resolution
    let fix: FrameFix?

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
                case .fixed:
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.ok)
                        EngravedLabel("fixed", color: Theme.ok)
                    }
                case .failed(let message):
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
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
