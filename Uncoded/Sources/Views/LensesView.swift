import SwiftUI
import SwiftData

/// The user's real lenses, engraved like barrel markings, with the borrowed
/// codes mapped to each.
struct LensesView: View {
    @Query(sort: \UserLens.name) private var lenses: [UserLens]
    @Environment(\.modelContext) private var context
    @State private var showAdd = false

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
                    Text("Add the third-party lenses you actually shoot with.\nUncoded finds their correction profiles in your Lightroom install.")
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
                                .contextMenu {
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

            if !lens.mappings.isEmpty {
                Divider().overlay(Theme.panelEdge)
                HStack(spacing: 14) {
                    EngravedLabel("answers as")
                    ForEach(lens.mappings) { mapping in
                        HStack(spacing: 6) {
                            BitPatternView(code: mapping.code, dotSize: 7)
                            Text(mapping.code)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
        }
        .instrumentCard()
        .frame(maxWidth: .infinity)
    }
}

/// Creates a lens, prefilled from the Adobe .lcp profiles installed locally.
private struct AddLensSheet: View {
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

    private var filtered: [LCPProfile] {
        guard !search.isEmpty else { return profiles }
        let q = search.lowercased()
        return profiles.filter {
            ($0.lensPrettyName ?? "").lowercased().contains(q) || $0.maker.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            EngravedLabel("add lens")

            TextField("Search Lightroom's M-mount lens profiles…", text: $search)
                .textFieldStyle(.roundedBorder)

            Group {
                if loading {
                    ProgressView("Indexing Adobe lens profiles…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if profiles.isEmpty {
                    Text("No Adobe lens profiles found. Is Lightroom or Camera Raw installed? You can still fill in the fields manually.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity)
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
                        }
                        .buttonStyle(.plain)
                    }
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
                }
            }

            Divider().overlay(Theme.panelEdge)

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

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add Lens") {
                    let lens = UserLens(name: name, make: make, focalLength: focalLength,
                                        aperture: aperture, profileName: profileName,
                                        profileFilename: profileFilename)
                    context.insert(lens)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 520)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
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
            let ap = Double(id.apertureX10) / 10
            aperture = ap == ap.rounded() ? "f/\(Int(ap))" : "f/\(ap)"
        }
    }
}
