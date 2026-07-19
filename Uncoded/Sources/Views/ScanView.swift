import SwiftUI
import SwiftData

/// Scans a folder of DNGs and shows what each file claims vs. the truth
/// according to the user's code mappings. Read-only for now.
struct ScanView: View {
    private enum Mode: String, CaseIterable {
        case sheet, list
    }

    @Query private var mappings: [CodeMapping]

    @State private var folder: URL?
    @State private var results: [ScannedDNG] = []
    @State private var scanning = false
    @State private var showPicker = false
    @State private var mode: Mode = .sheet

    private var mappingByCode: [String: CodeMapping] {
        Dictionary(mappings.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty && !scanning {
                dropZone
            } else {
                resultsArea
            }
        }
        .background(Theme.bg)
        .navigationTitle("Scan")
        .toolbar {
            if !results.isEmpty {
                Picker("View", selection: $mode) {
                    Image(systemName: "square.grid.3x2").tag(Mode.sheet)
                    Image(systemName: "list.bullet").tag(Mode.list)
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
                if let folder {
                    Text(folder.path)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                if scanning {
                    ProgressView().controlSize(.small)
                } else {
                    stat("\(results.count)", "frames")
                    stat("\(results.filter { $0.matchedCode != nil }.count)", "coded")
                    stat("\(results.filter { mapped($0) != nil }.count)", "mapped")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Theme.panelEdge)

            switch mode {
            case .sheet:
                ContactSheet(results: results, realLens: mapped)
            case .list:
                List(results) { file in
                    ScanRow(file: file, realLens: mapped(file))
                        .listRowSeparatorTint(Theme.panelEdge)
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.engraved)
            EngravedLabel(label, color: Theme.faint)
        }
    }

    private func mapped(_ file: ScannedDNG) -> UserLens? {
        guard let code = file.matchedCode?.code else { return nil }
        return mappingByCode[code]?.lens
    }

    private func scan(_ url: URL) {
        folder = url
        scanning = true
        results = []
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                DNGScanner.scan(folder: url)
            }.value
            results = found
            scanning = false
        }
    }
}

// MARK: - Contact sheet

/// The scan as a film contact sheet: black frames on a dark ground, with the
/// filename and code printed beneath each frame like edge markings on the
/// rebate of a strip of film.
private struct ContactSheet: View {
    let results: [ScannedDNG]
    let realLens: (ScannedDNG) -> UserLens?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 178, maximum: 260), spacing: 14)],
                      spacing: 16) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, file in
                    FrameCell(file: file, frameNumber: index + 1, realLens: realLens(file))
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
    let realLens: UserLens?

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
                        .foregroundStyle(Theme.rebate)
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
                    if let realLens {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 7))
                            .foregroundStyle(Theme.ok)
                        Text(realLens.name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.ok)
                            .lineLimit(1)
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black)
        }
        .overlay(Rectangle().strokeBorder(Theme.panelEdge.opacity(0.6), lineWidth: 1))
        .help(helpText)
        .task { image = await ThumbnailLoader.thumbnail(for: file.url) }
    }

    private var helpText: String {
        var lines = [file.filename]
        if let claimed = file.claimedLens { lines.append("claims: \(claimed)") }
        if let code = file.matchedCode { lines.append("code \(code.code) — \(code.lensName)") }
        if let realLens { lines.append("actually: \(realLens.name)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - List rows

private struct ScanRow: View {
    let file: ScannedDNG
    let realLens: UserLens?

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

                if let realLens {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.ok)
                        Text(realLens.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.ok)
                            .lineLimit(1)
                    }
                } else if file.matchedCode != nil {
                    Text("code not mapped to one of your lenses")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}
