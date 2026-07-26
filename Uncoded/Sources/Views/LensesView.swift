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
                                    Button("Delete", role: .destructive) { delete(lens) }
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

    /// A live scan may hold this lens as a per-frame override; tell it to let
    /// go before SwiftData invalidates the model.
    private func delete(_ lens: UserLens) {
        NotificationCenter.default.post(name: .uncodedLensWillDelete,
                                        object: lens.persistentModelID)
        context.delete(lens)
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

/// Reassigns which 6-bit code an existing lens wears. A lens can wear more
/// than one code over its life (re-coded: old files carry A, new ones B), so
/// the sheet edits one of them at a time and leaves the others alone.
private struct ChangeCodeSheet: View {
    let lens: UserLens
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    /// Which of the lens's existing codes is being edited. `mappings` has no
    /// stable order, so a lens wearing several lets the user say which.
    @State private var editing: String?
    private let currentCodes: [String]

    init(lens: UserLens) {
        self.lens = lens
        currentCodes = lens.mappings.map(\.code).sorted()
        _editing = State(initialValue: currentCodes.first)
        _selection = State(initialValue: currentCodes.first)
    }

    private var keptCodes: [String] {
        currentCodes.filter { $0 != editing }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                EngravedLabel("coded as")
                Text(lens.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.engraved)
            }

            if currentCodes.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    EngravedLabel("editing", color: Theme.faint)
                    HStack(spacing: 8) {
                        ForEach(currentCodes, id: \.self) { code in
                            Button {
                                editing = code
                                selection = code
                            } label: {
                                codeChip(code, active: editing == code)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            CodePickerList(suggestionSeed: lens.name, selection: $selection,
                           extraCodes: currentCodes)

            if !keptCodes.isEmpty {
                HStack(spacing: 10) {
                    EngravedLabel("also wears", color: Theme.faint)
                    ForEach(keptCodes, id: \.self) { code in
                        HStack(spacing: 5) {
                            BitPatternView(code: code, dotSize: 7)
                            Text(code)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    Text("— kept")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                // Clicking the current code again clears the selection, which
                // un-codes the lens on save — name that instead of letting it
                // hide behind a plain "Save", and don't put it on Return.
                if selection == nil {
                    if editing != nil {
                        Button("Remove Code", role: .destructive) { save() }
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

    /// One of the lens's codes, engraved on a small plate.
    private func codeChip(_ code: String, active: Bool) -> some View {
        HStack(spacing: 6) {
            BitPatternView(code: code, dotSize: 7)
            Text(code)
                .font(Theme.mono(10))
                .foregroundStyle(active ? Theme.engraved : Theme.dim)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(active ? Theme.accent.opacity(0.8) : Theme.panelEdge, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
    }

    private func save() {
        Mappings.replace(editing, with: selection, for: lens, in: context)
        dismiss()
    }
}

/// Mapping bookkeeping shared by the sheets: one code belongs to one lens.
enum Mappings {
    /// Points `code` at `lens`, stealing it from any other lens that had it.
    static func assign(code: String, to lens: UserLens, in context: ModelContext) {
        // No lens row for a code the table doesn't list (a mapping made before
        // the placeholder slots were filtered out) — keep whatever name it had.
        let leicaName = SixBitTable.byCode[code]?.first?.lensName
        let descriptor = FetchDescriptor<CodeMapping>(predicate: #Predicate { $0.code == code })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.lens = lens
            if let leicaName { existing.leicaLensName = leicaName }
        } else {
            context.insert(CodeMapping(code: code, leicaLensName: leicaName ?? "", lens: lens))
        }
    }

    /// Swaps one of the lens's codes for another (or drops it when `new` is
    /// nil). The lens's other codes stay: a re-coded lens really does wear one
    /// code on its old files and another on the new ones.
    static func replace(_ old: String?, with new: String?, for lens: UserLens, in context: ModelContext) {
        if let old, old != new, let mapping = lens.mappings.first(where: { $0.code == old }) {
            context.delete(mapping)
        }
        if let new, !lens.mappings.contains(where: { $0.code == new }) {
            assign(code: new, to: lens, in: context)
        }
    }
}
