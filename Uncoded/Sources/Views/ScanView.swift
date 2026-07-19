import SwiftUI
import SwiftData

/// Scans a folder of DNGs and shows what each file claims vs. the truth
/// according to the user's code mappings. Read-only for now.
struct ScanView: View {
    @Query private var mappings: [CodeMapping]

    @State private var folder: URL?
    @State private var results: [ScannedDNG] = []
    @State private var scanning = false
    @State private var showPicker = false

    private var mappingByCode: [String: CodeMapping] {
        Dictionary(mappings.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(spacing: 0) {
            if results.isEmpty && !scanning {
                dropZone
            } else {
                resultsList
            }
        }
        .background(Theme.bg)
        .navigationTitle("Scan")
        .toolbar {
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

    private var resultsList: some View {
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
                    stat("\(results.count)", "files")
                    stat("\(results.filter { $0.matchedCode != nil }.count)", "coded")
                    stat("\(results.filter { mapped($0) != nil }.count)", "mapped")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().overlay(Theme.panelEdge)

            List(results) { file in
                ScanRow(file: file, realLens: mapped(file))
                    .listRowSeparatorTint(Theme.panelEdge)
            }
            .scrollContentBackground(.hidden)
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
