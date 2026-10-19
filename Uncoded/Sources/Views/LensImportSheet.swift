import SwiftUI
import SwiftData

struct LensImportRequest: Identifiable {
    let id = UUID()
    let files: [URL]
    var isSetup = false
}

struct LensImportSheet: View {
    let request: LensImportRequest
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var lenses: [UserLens]
    @Query private var mappings: [CodeMapping]
    @State private var selections: [LensEntryImport.Selection] = []
    @State private var failures: [ReferenceLensImporter.Failure] = []
    @State private var selectedID: UUID?
    @State private var loading = true
    @State private var error: String?

    private var count: Int { selections.filter(\.included).count }
    private var validation: String? {
        LensEntryImport.validation(selections, lenses: lenses, mappings: mappings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isSetup ? "Import Lens Setup" : "Extract Lens Metadata")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.engraved)
            Text(request.isSetup
                 ? "Review the saved lenses, profile references, and code mappings before adding them to My Lenses."
                 : "Review lens details copied from the reference files. Identical entries are grouped; conflicting variants can be reviewed separately.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)

            if loading {
                ProgressView("Reading lens metadata…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selections.isEmpty {
                ContentUnavailableView("No Lens Entries Found", systemImage: "camera.aperture",
                                       description: Text("Choose files containing lens metadata, or a lens setup exported by Uncoded."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    List(selection: $selectedID) {
                        ForEach($selections) { $selection in
                            HStack(alignment: .top, spacing: 8) {
                                Toggle("Import \(selection.entry.name)", isOn: $selection.included)
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selection.entry.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(selection.entry.sourceFilenames.joined(separator: ", "))
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.dim)
                                        .lineLimit(2)
                                    if lenses.contains(where: { LensEntryImport.nameKey($0.name) == LensEntryImport.nameKey(selection.entry.name) }) {
                                        Text("Already in My Lenses")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(selection.id)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .frame(width: 240)

                    if let index = selections.firstIndex(where: { $0.id == selectedID }) {
                        LensImportEditor(selection: $selections[index], isSetup: request.isSetup)
                            .id(selections[index].id)
                    } else {
                        Text("Select an entry to review its details.")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundStyle(Theme.dim)
                    }
                }
            }

            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) file\(failures.count == 1 ? "" : "s") could not be read") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(failures) { failure in
                                Text("\(failure.filename): \(failure.message)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 90)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            }

            if !loading, let validation {
                Text(validation)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import \(count) Lens\(count == 1 ? "" : "es")") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || validation != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 1050, minHeight: 650)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .task { await read() }
        .alert("Couldn’t Import Lenses", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @MainActor
    private func read() async {
        let files = request.files
        let setup = request.isSetup
        let result = await Task.detached(priority: .userInitiated) {
            if setup {
                do {
                    guard let file = files.first else { return ([LensEntryImport.Selection](), [ReferenceLensImporter.Failure]()) }
                    return (try LensSetupArchive.read(file), [])
                } catch {
                    return ([], [ReferenceLensImporter.Failure(filename: files.first?.lastPathComponent ?? "Setup", message: error.localizedDescription)])
                }
            }
            let result = ReferenceLensImporter.read(files)
            return (result.entries.map { LensEntryImport.Selection(entry: $0) }, result.failures)
        }.value
        guard !Task.isCancelled else { return }
        let existing = Set(lenses.map { LensEntryImport.nameKey($0.name) })
        var seen = Set<String>()
        selections = result.0.map { selection in
            var selection = selection
            let key = LensEntryImport.nameKey(selection.entry.name)
            selection.included = !existing.contains(key) && seen.insert(key).inserted
            return selection
        }
        failures = result.1
        selectedID = selections.first?.id
        loading = false
    }

    @MainActor
    private func save() {
        do {
            _ = try LensEntryImport.save(selections, in: context)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct LensImportEditor: View {
    @Binding var selection: LensEntryImport.Selection
    let isSetup: Bool

    private var codeSelection: Binding<String?> {
        Binding(get: { selection.codes.last }, set: { code in
            if let code {
                if !selection.codes.contains(code) { selection.codes.append(code) }
            } else if !selection.codes.isEmpty {
                selection.codes.removeLast()
            }
        })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    EngravedLabel("lens details")
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                        GridRow { Text("Name"); TextField("Lens name", text: $selection.entry.name) }
                        GridRow { Text("Make"); TextField("Lens maker", text: $selection.entry.make) }
                        GridRow { Text("Focal"); TextField("35mm", text: $selection.entry.focalLength) }
                        GridRow { Text("Aperture"); TextField("f/2", text: $selection.entry.aperture) }
                        GridRow { Text("Profile"); TextField("Profile name", text: $selection.entry.profileName) }
                        GridRow { Text("Filename"); TextField("Profile .lcp filename", text: $selection.entry.profileFilename) }
                        GridRow { Text("Digest"); TextField("Profile digest", text: $selection.entry.profileDigest) }
                    }
                    .font(.system(size: 12))
                    .textFieldStyle(.roundedBorder)
                    Text("Profile details are references to Adobe profiles. Lightroom / Camera Raw must provide the matching profile on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                    if !isSetup {
                        Text("These fields reflect what the file claims. An uncorrected file may still name its borrowed Leica lens.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                    Divider().overlay(Theme.panelEdge)
                    EngravedLabel("code mappings")
                    if selection.codes.isEmpty {
                        Text("No code selected. You can assign one later in My Lenses.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                    }
                    ForEach(selection.codes, id: \.self) { code in
                        HStack {
                            BitPatternView(code: code, dotSize: 8)
                            Text(code).font(Theme.mono(11))
                            Spacer()
                            Button {
                                selection.codes.removeAll { $0 == code }
                            } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("Remove code \(code) from this import")
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity)
            Divider().overlay(Theme.panelEdge)
            VStack(alignment: .leading, spacing: 8) {
                EngravedLabel("add a code")
                Text(isSetup ? "Saved codes are preserved. Select a code to add another mapping."
                     : "Corrected DNGs may no longer identify the borrowed code. Choose it here, or leave it unmapped.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                CodePickerList(suggestionSeed: selection.entry.name, selection: codeSelection,
                               extraCodes: selection.codes)
            }
            .frame(width: 290)
        }
    }
}
