import SwiftUI
import SwiftData

/// The user's real lenses, engraved like barrel markings. The 6-bit code a
/// lens wears is part of its identity, so it's chosen when the lens is added
/// and shown on the card — no separate mapping step.
struct LensesView: View {
    @Query(sort: \UserLens.name) private var lenses: [UserLens]
    @Environment(\.modelContext) private var context
    @State private var showAdd = false
    @State private var lensToRecode: UserLens?

    var body: some View {
        Group {
            if lenses.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(Theme.faint)
                    Text("No lenses yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.engraved)
                    Text("Add a lens and the 6-bit code it wears — one step.\nUncoded finds correction profiles in your Lightroom install\nand suggests the code Leica shooters borrow for those specs.")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                    Button("Add Lens…") { showAdd = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(lenses) { lens in
                            LensCard(lens: lens)
                                .onTapGesture { lensToRecode = lens }
                                .contextMenu {
                                    Button("Change Code…") { lensToRecode = lens }
                                    Button("Delete", role: .destructive) { context.delete(lens) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Theme.bg)
        .navigationTitle("My Lenses")
        .toolbar {
            Button {
                showAdd = true
            } label: {
                Label("Add Lens", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showAdd) { AddLensSheet() }
        .sheet(item: $lensToRecode) { lens in ChangeCodeSheet(lens: lens) }
    }
}

private struct LensCard: View {
    let lens: UserLens

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(lens.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.engraved)
                Spacer()
                Text("\(lens.focalLength)  \(lens.aperture)")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.dim)
            }

            if !lens.profileName.isEmpty {
                HStack(spacing: 6) {
                    EngravedLabel("profile")
                    Text(lens.profileName)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
            }

            Divider().overlay(Theme.panelEdge)

            if lens.mappings.isEmpty {
                HStack(spacing: 8) {
                    EngravedLabel("uncoded", color: Theme.accent)
                    Text("tap to assign the 6-bit code this lens wears")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
            } else {
                HStack(spacing: 14) {
                    EngravedLabel("coded as")
                    ForEach(lens.mappings) { mapping in
                        HStack(spacing: 7) {
                            BitPatternView(code: mapping.code, dotSize: 8)
                            Text(mapping.code)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.engraved)
                            if !mapping.leicaLensName.isEmpty {
                                Text(mapping.leicaLensName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.faint)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .instrumentCard(highlighted: !lens.mappings.isEmpty)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// One-step lens creation: pick the lens (left, from the local Adobe profile
/// index) and the 6-bit code it wears (right, best suggestion first).
/// `preselectedCode` seeds the code side (used when arriving from a scan
/// that found an unclaimed code) and is treated as the user's own choice.
struct AddLensSheet: View {
    var preselectedCode: String? = nil

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [LCPProfile] = []
    @State private var loading = true
    @State private var search = ""

    @State private var name = ""
    @State private var make = ""
    @State private var focalLength = ""
    @State private var aperture = ""
    @State private var profileName = ""
    @State private var profileFilename = ""
    @State private var selectedCode: String?
    @State private var codeAutoSelected = true

    private var filtered: [LCPProfile] {
        guard !search.isEmpty else { return profiles }
        return profiles.filter { Search.matches(search, in: [$0.lensPrettyName, $0.maker]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngravedLabel("add lens")

            HStack(alignment: .top, spacing: 16) {
                // Left: which lens is it?
                VStack(alignment: .leading, spacing: 8) {
                    EngravedLabel("your lens", color: Theme.faint)
                    TextField("Search Lightroom's M-mount lens profiles…", text: $search)
                        .textFieldStyle(.roundedBorder)

                    if loading {
                        ProgressView("Indexing Adobe lens profiles…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if profiles.isEmpty {
                        Text("No Adobe lens profiles found. Is Lightroom or Camera Raw installed? You can still fill in the fields manually.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        List(filtered) { profile in
                            Button {
                                fill(from: profile)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.lensPrettyName ?? profile.url.lastPathComponent)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Theme.engraved)
                                        Text(profile.maker)
                                            .font(Theme.mono(10))
                                            .foregroundStyle(Theme.dim)
                                    }
                                    Spacer()
                                    if profileName == (profile.profileName ?? "") && !profileName.isEmpty {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowSeparatorTint(Theme.panelEdge)
                        }
                        .scrollContentBackground(.hidden)
                    }

                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                        GridRow {
                            EngravedLabel("name")
                            TextField("Voigtlander VM 35mm f/2 Ultron Aspherical", text: $name)
                        }
                        GridRow {
                            EngravedLabel("make")
                            TextField("Voigtlander", text: $make)
                        }
                        GridRow {
                            EngravedLabel("focal")
                            TextField("35.0mm", text: $focalLength)
                        }
                        GridRow {
                            EngravedLabel("aperture")
                            TextField("f/2", text: $aperture)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }

                Divider().overlay(Theme.panelEdge)

                // Right: which code is engraved on it?
                VStack(alignment: .leading, spacing: 8) {
                    EngravedLabel("coded as", color: Theme.faint)
                    CodePickerList(suggestionSeed: name, selection: $selectedCode,
                                   onUserSelect: { codeAutoSelected = false })
                }
                .frame(width: 340)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                if selectedCode == nil {
                    Text("pick the code this lens wears")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
                Button("Add Lens") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 800, minHeight: 560)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            if let preselectedCode, selectedCode == nil {
                selectedCode = preselectedCode
                codeAutoSelected = false
            }
        }
        .task {
            let found = await Task.detached(priority: .userInitiated) {
                LCPIndex.indexMMount()
            }.value
            profiles = found
            loading = false
        }
    }

    private func fill(from profile: LCPProfile) {
        let pretty = profile.lensPrettyName ?? ""
        name = pretty
        make = pretty.split(separator: " ").first.map(String.init) ?? profile.maker
        profileName = profile.profileName ?? ""
        profileFilename = profile.url.lastPathComponent
        if let id = LensNameParser.parse(pretty) {
            focalLength = "\(id.focalMM).0mm"
            let ap = Double(id.apertureX100) / 100
            aperture = ap == ap.rounded() ? "f/\(Int(ap))" : "f/\(ap)"
            // Re-suggest the most plausible borrowed code for the new specs —
            // but never override a code the user picked themselves.
            if codeAutoSelected {
                selectedCode = SixBitTable.ranked(for: id).first
            }
        }
    }

    private func save() {
        let lens = UserLens(name: name, make: make, focalLength: focalLength,
                            aperture: aperture, profileName: profileName,
                            profileFilename: profileFilename)
        context.insert(lens)
        if let code = selectedCode {
            Mappings.assign(code: code, to: lens, in: context)
        }
        dismiss()
    }
}

/// Reassigns which 6-bit code an existing lens wears.
private struct ChangeCodeSheet: View {
    let lens: UserLens
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    private let hadCode: Bool

    init(lens: UserLens) {
        self.lens = lens
        hadCode = lens.mappings.first != nil
        _selection = State(initialValue: lens.mappings.first?.code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                EngravedLabel("coded as")
                Text(lens.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.engraved)
            }

            CodePickerList(suggestionSeed: lens.name, selection: $selection)

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                // Clicking the current code again clears the selection, which
                // un-codes the lens on save — name that instead of letting it
                // hide behind a plain "Save".
                if selection == nil {
                    if hadCode {
                        Button("Remove Code", role: .destructive) { save() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Text("pick the code this lens wears")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(true)
                    }
                } else {
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 480)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func save() {
        Mappings.set(code: selection, for: lens, in: context)
        dismiss()
    }
}

/// Mapping bookkeeping shared by the sheets: one code belongs to one lens.
enum Mappings {
    /// Points `code` at `lens`, stealing it from any other lens that had it.
    static func assign(code: String, to lens: UserLens, in context: ModelContext) {
        let leicaName = SixBitTable.byCode[code]?.first?.lensName ?? ""
        let descriptor = FetchDescriptor<CodeMapping>(predicate: #Predicate { $0.code == code })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.lens = lens
            existing.leicaLensName = leicaName
        } else {
            context.insert(CodeMapping(code: code, leicaLensName: leicaName, lens: lens))
        }
    }

    /// Replaces the lens's mapping with `code` (or removes it when nil).
    static func set(code: String?, for lens: UserLens, in context: ModelContext) {
        for mapping in lens.mappings where mapping.code != code {
            context.delete(mapping)
        }
        if let code, !lens.mappings.contains(where: { $0.code == code }) {
            assign(code: code, to: lens, in: context)
        }
    }
}
